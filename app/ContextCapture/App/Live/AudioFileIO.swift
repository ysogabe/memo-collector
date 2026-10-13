import AVFoundation
import Foundation

/// 注釈の音声ファイル（16kHz モノラル 16bit PCM の WAV）の読み書き。
///
/// PRD §7 の例は `.m4a` だが、M1 は録音器（`PushToTalkRecorder`）が書く WAV をそのまま添付にする
/// （AAC へのエンコードを保存の経路に入れない。16kHz/16bit で 32KB/秒、30 秒で約 1MB。既定 7 日で消える）。
enum AudioFileIO {
    static let sampleRate: Double = 16_000

    enum AudioFileError: Error, Equatable {
        case unreadable(String)
    }

    /// Float32 サンプル（-1…1）を 16bit PCM の WAV にする（録音器が一時ファイルを書かなかったとき用）。
    static func wavData(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let dataBytes = samples.count * 2
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * Float(Int16.max))
            u16(UInt16(bitPattern: v))
        }
        return d
    }

    /// 音声ファイルを 16kHz モノラル Float32 で読む（文字起こしの再試行用）。16kHz 以外はリサンプルする。
    static func readMono16k(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioFileError.unreadable("\(error)") }
        let inFormat = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw AudioFileError.unreadable("format") }
        do { try file.read(into: inBuffer) } catch { throw AudioFileError.unreadable("\(error)") }

        if inFormat.sampleRate == sampleRate, inFormat.channelCount == 1, inFormat.commonFormat == .pcmFormatFloat32,
           let ch = inBuffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: inFormat, to: target) else { throw AudioFileError.unreadable("converter") }
        let ratio = sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw AudioFileError.unreadable("buffer") }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        guard status != .error, let ch = out.floatChannelData else {
            throw AudioFileError.unreadable(convError.map { "\($0)" } ?? "convert")
        }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}
