import Foundation

/// WhisperKit に渡す前の「声が入っているか」の判定（無音・極端に短い入力を弾く）。
///
/// Whisper は無音や環境雑音だけの入力でも「ご視聴ありがとうございました」のような幻聴を返すうえ、
/// 1 回 1 秒以上かかる。そこで 20ms フレームの RMS（dBFS）を見て、発話らしい音量のフレームが
/// 一定時間以上あるときだけ通す。
///
/// 閾値の根拠（Tests/CCSTTTests/SpeechGateTests.swift で固定）:
/// - fixtures 30 件（TTS 音声）: 発話フレームの中央値は -28〜-17 dBFS、-45 dBFS 超のフレームは最短でも 1.7 秒ぶん
/// - マイクの環境雑音は概ね -60〜-50 dBFS。-45 dBFS 未満は「無音」とみなす
/// - 発話の最短（「はい」程度）でも 0.15 秒以上は -45 dBFS を超える
public struct SpeechGate: Sendable, Equatable {
    /// この長さ未満の入力は判定せず `tooShort`。
    public var minimumDuration: TimeInterval
    /// 発話とみなすフレームの RMS 下限（dBFS）。
    public var activeFrameThresholdDBFS: Float
    /// 発話フレームの合計がこの秒数未満なら `silent`。
    public var minimumActiveDuration: TimeInterval
    /// サンプルレート（16kHz 固定。テスト用に変えられる）。
    public var sampleRate: Double

    /// 1 フレームの長さ（秒）。
    public static let frameDuration: TimeInterval = 0.02

    public init(
        minimumDuration: TimeInterval = 0.3,
        activeFrameThresholdDBFS: Float = -45,
        minimumActiveDuration: TimeInterval = 0.15,
        sampleRate: Double = 16_000
    ) {
        self.minimumDuration = minimumDuration
        self.activeFrameThresholdDBFS = activeFrameThresholdDBFS
        self.minimumActiveDuration = minimumActiveDuration
        self.sampleRate = sampleRate
    }

    /// 入力の要約。
    public struct Analysis: Sendable, Equatable {
        /// 入力の長さ（秒）。
        public var duration: TimeInterval
        /// 閾値を超えたフレームの合計秒数。
        public var activeDuration: TimeInterval
        /// フレーム RMS の最大値（dBFS）。無音（全 0）は -infinity ではなく -200 にしてある。
        public var peakFrameDBFS: Float
    }

    /// フレームごとの RMS を測る。
    public func analyze(_ samples: [Float]) -> Analysis {
        let duration = Double(samples.count) / sampleRate
        let frameLength = max(1, Int(sampleRate * Self.frameDuration))
        var active = 0
        var peak: Float = -200
        var start = 0
        samples.withUnsafeBufferPointer { buf in
            while start < buf.count {
                let end = min(buf.count, start + frameLength)
                var sum: Float = 0
                for i in start..<end { sum += buf[i] * buf[i] }
                let rms = (sum / Float(end - start)).squareRoot()
                let db: Float = rms > 1e-10 ? 20 * log10(rms) : -200
                if db > peak { peak = db }
                // 末尾の半端なフレームは長さに比例して数える
                if db >= activeFrameThresholdDBFS { active += end - start }
                start = end
            }
        }
        return Analysis(duration: duration, activeDuration: Double(active) / sampleRate, peakFrameDBFS: peak)
    }

    /// 声が入っていなければ理由を返す（入っていれば nil）。
    public func rejectionReason(for samples: [Float]) -> STTError.NoSpeechReason? {
        let a = analyze(samples)
        if a.duration < minimumDuration { return .tooShort }
        if a.activeDuration < minimumActiveDuration { return .silent }
        return nil
    }
}
