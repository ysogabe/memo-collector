import AVFoundation
import CCCore
import Foundation

/// 入力フォーマット → 16kHz モノラル Float32 の変換器。1 回の録音で 1 つを使い回す（リサンプラの状態を保つため）。
///
/// 多チャンネルはチャンネルの**平均**でモノラルにしてから（Float32 入力のとき）、AVAudioConverter で 16kHz に落とす。
/// Float32 以外の入力は AVAudioConverter の `downmix` に任せる。スレッド安全ではない（呼び出し側で直列化する）。
final class AudioResampler {
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: RecordedAudio.sampleRate,
        channels: 1,
        interleaved: false
    )!

    enum ResamplerError: Error { case unsupportedFormat }

    let inputFormat: AVAudioFormat
    /// 変換器に渡す直前のフォーマット（Float32 入力ならモノラル化後）。
    private let converterInputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let downmixesManually: Bool
    private var finished = false

    init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw ResamplerError.unsupportedFormat }
        self.inputFormat = inputFormat
        if inputFormat.commonFormat == .pcmFormatFloat32 {
            downmixesManually = true
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false) else {
                throw ResamplerError.unsupportedFormat
            }
            converterInputFormat = mono
        } else {
            downmixesManually = false
            converterInputFormat = inputFormat
        }
        guard let c = AVAudioConverter(from: converterInputFormat, to: Self.outputFormat) else {
            throw ResamplerError.unsupportedFormat
        }
        c.downmix = true
        c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter = c
    }

    /// 1 バッファ分を変換する。
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard !finished, buffer.frameLength > 0 else { return [] }
        let input: AVAudioPCMBuffer
        if downmixesManually {
            guard let mono = Self.downmixToMono(buffer, format: converterInputFormat) else { return [] }
            input = mono
        } else {
            input = buffer
        }
        var supplied = false
        return drain(frames: Int(input.frameLength)) { status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
    }

    /// 変換器に残ったサンプルを出し切る。以後 `convert` は何もしない。
    func flush() -> [Float] {
        guard !finished else { return [] }
        finished = true
        return drain(frames: 0) { status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func drain(frames: Int, input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) -> [Float] {
        let ratio = Self.outputFormat.sampleRate / converterInputFormat.sampleRate
        let capacity = AVAudioFrameCount(max(1024, Int((Double(frames) * ratio).rounded(.up)) + 1024))
        var out: [Float] = []
        // 1 回で出し切れなければ繰り返す（上限付き）。
        for _ in 0 ..< 64 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: buf, error: &error) { _, s in input(s) }
            if buf.frameLength > 0, let ch = buf.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
            }
            switch status {
            case .haveData:
                if buf.frameLength == 0 { return out }
                continue
            case .inputRanDry, .endOfStream, .error:
                return out
            @unknown default:
                return out
            }
        }
        return out
    }

    /// Float32 の多チャンネル（インターリーブ / 非インターリーブとも）をチャンネル平均でモノラルにする。
    static func downmixToMono(_ buffer: AVAudioPCMBuffer, format mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)),
              let dst = out.floatChannelData?[0],
              let src = buffer.floatChannelData
        else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        if channels == 1 {
            dst.update(from: src[0], count: frames)
            return out
        }
        let scale = 1 / Float(channels)
        if buffer.format.isInterleaved {
            let p = src[0]
            for i in 0 ..< frames {
                var sum: Float = 0
                for c in 0 ..< channels { sum += p[i * channels + c] }
                dst[i] = sum * scale
            }
        } else {
            for i in 0 ..< frames {
                var sum: Float = 0
                for c in 0 ..< channels { sum += src[c][i] }
                dst[i] = sum * scale
            }
        }
        return out
    }
}

/// HUD の波形用レベル。
public enum LevelMeter {
    /// これ以下（dBFS）は 0 とみなす。
    public static let floorDecibels: Float = -60

    /// RMS（0–1 のフルスケール基準）を 0–1 に正規化する。−60dBFS → 0、0dBFS → 1 の線形（dB 上）。
    public static func normalizedLevel(rms: Float, floorDecibels: Float = floorDecibels) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let v = (db - floorDecibels) / -floorDecibels
        return min(1, max(0, v))
    }

    public static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// 16kHz サンプルを 50ms（800 サンプル）ごとに区切ってレベルを出す（約 20Hz）。
/// ハードウェアのバッファ長は指定どおりにならないので、変換後のサンプル数で窓を切る。
struct LevelWindow {
    static let windowSize = Int(RecordedAudio.sampleRate / 20)
    private var pending: [Float] = []

    init() { pending.reserveCapacity(Self.windowSize * 2) }

    mutating func append(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        var levels: [Float] = []
        while pending.count >= Self.windowSize {
            levels.append(LevelMeter.normalizedLevel(rms: LevelMeter.rms(pending[0 ..< Self.windowSize])))
            pending.removeFirst(Self.windowSize)
        }
        return levels
    }
}

/// 16bit PCM の WAV（RIFF）を組み立てる。
enum WAVEncoder {
    static func encodePCM16(samples: [Float], sampleRate: Int = Int(RecordedAudio.sampleRate)) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * blockAlign
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)  // PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        d.append(contentsOf: Array("data".utf8))
        u32(dataSize)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            let c = s.isFinite ? min(1, max(-1, s)) : 0
            pcm[i] = Int16((c * 32767).rounded()).littleEndian
        }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
