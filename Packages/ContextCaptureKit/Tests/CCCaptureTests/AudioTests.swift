import AVFoundation
import CCCore
import XCTest
@testable import CCCapture

/// 変換・レベル・WAV の純粋ロジックと、権限が無いときの録音器の振る舞い。
/// AVAudioEngine の start / タップは実機（マイク）でしか確かめられないので、ここでは触らない。
final class AudioTests: XCTestCase {
    private func sine(rate: Double, seconds: Double, freq: Double = 440, amp: Float = 0.5, channels: AVAudioChannelCount = 1,
                      interleaved: Bool = false, silentRight: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let data = buf.floatChannelData!
        for i in 0 ..< Int(frames) {
            let v = amp * Float(sin(2 * Double.pi * freq * Double(i) / rate))
            for c in 0 ..< Int(channels) {
                let x: Float = (silentRight && c == 1) ? 0 : v
                if interleaved { data[0][i * Int(channels) + c] = x } else { data[c][i] = x }
            }
        }
        return buf
    }

    /// 1 秒を細切れ（ハードウェアのバッファ相当）にして流し、最後に flush。
    private func convertInChunks(_ buf: AVAudioPCMBuffer, chunk: Int = 1024) throws -> [Float] {
        let r = try AudioResampler(inputFormat: buf.format)
        var out: [Float] = []
        var offset = 0
        let total = Int(buf.frameLength)
        let ch = Int(buf.format.channelCount)
        while offset < total {
            let n = min(chunk, total - offset)
            let piece = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(n))!
            piece.frameLength = AVAudioFrameCount(n)
            if buf.format.isInterleaved {
                piece.floatChannelData![0].update(from: buf.floatChannelData![0] + offset * ch, count: n * ch)
            } else {
                for c in 0 ..< ch { piece.floatChannelData![c].update(from: buf.floatChannelData![c] + offset, count: n) }
            }
            out += r.convert(piece)
            offset += n
        }
        out += r.flush()
        XCTAssertEqual(r.flush(), [], "flush は 1 回だけ")
        return out
    }

    /// 端（フィルタの立ち上がり）を除いた中央部分の RMS。
    private func middleRMS(_ s: [Float]) -> Float {
        LevelMeter.rms(s[s.count / 10 ..< s.count * 9 / 10])
    }

    func testResample48kMonoTo16k() throws {
        let out = try convertInChunks(sine(rate: 48_000, seconds: 1))
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 64, "長さ（1 秒 = 16000）")
        XCTAssertEqual(middleRMS(out), 0.5 / 2.0.squareRoot().float, accuracy: 0.02, "振幅が保たれる")
        XCTAssertLessThan(out.map(abs).max()!, 0.56)
        // 周波数: ゼロ交差の数（440Hz × 2 × 1 秒 ≈ 880）
        var crossings = 0
        for i in 1 ..< out.count where (out[i - 1] < 0) != (out[i] < 0) { crossings += 1 }
        XCTAssertEqual(Double(crossings), 880, accuracy: 10)
    }

    func testResample44_1kStereoNonInterleavedAverages() throws {
        let out = try convertInChunks(sine(rate: 44_100, seconds: 1, channels: 2, silentRight: true), chunk: 512)
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 64)
        // L = 0.5 の正弦、R = 無音 → 平均で振幅 0.25
        XCTAssertEqual(middleRMS(out), 0.25 / 2.0.squareRoot().float, accuracy: 0.01)
    }

    func testResampleInterleavedStereo() throws {
        let out = try convertInChunks(sine(rate: 48_000, seconds: 0.5, channels: 2, interleaved: true))
        XCTAssertEqual(Double(out.count), 8_000, accuracy: 64)
        XCTAssertEqual(middleRMS(out), 0.5 / 2.0.squareRoot().float, accuracy: 0.02)
    }

    func testResample16kPassThroughLength() throws {
        let out = try convertInChunks(sine(rate: 16_000, seconds: 1))
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 32)
    }

    func testResamplerRejectsInvalidFormat() {
        let bad = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false)
        if let bad {
            XCTAssertThrowsError(try AudioResampler(inputFormat: bad))
            XCTAssertFalse(PushToTalkRecorder.isUsable(bad))
        }
        XCTAssertTrue(PushToTalkRecorder.isUsable(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!))
    }

    func testLevelNormalization() {
        XCTAssertEqual(LevelMeter.normalizedLevel(rms: 1), 1)
        XCTAssertEqual(LevelMeter.normalizedLevel(rms: 2), 1, "クリップ")
        XCTAssertEqual(LevelMeter.normalizedLevel(rms: 0), 0)
        XCTAssertEqual(LevelMeter.normalizedLevel(rms: .nan), 0)
        XCTAssertEqual(LevelMeter.normalizedLevel(rms: 0.001), 0, accuracy: 1e-5, "-60dBFS が下限")
        XCTAssertEqual(LevelMeter.normalizedLevel(rms: 0.0001), 0)
        XCTAssertEqual(LevelMeter.normalizedLevel(rms: 0.1), 2.0 / 3.0, accuracy: 1e-4, "-20dBFS")
        XCTAssertEqual(LevelMeter.normalizedLevel(rms: 0.0316228), 0.5, accuracy: 1e-3, "-30dBFS")
        XCTAssertEqual(LevelMeter.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(LevelMeter.rms([Float]()), 0)
    }

    func testLevelWindowEmitsAbout20Hz() {
        var w = LevelWindow()
        var levels: [Float] = []
        // 1 秒分を半端な長さで流す
        let second = [Float](repeating: 0.1, count: 16_000)
        var i = 0
        for n in [333, 1024, 77, 5000, 9566] {
            levels += w.append(Array(second[i ..< i + n]))
            i += n
        }
        XCTAssertEqual(i, 16_000)
        XCTAssertEqual(levels.count, 20)
        for l in levels { XCTAssertEqual(l, 2.0 / 3.0, accuracy: 1e-3) }
    }

    func testWAVHeader() {
        let d = WAVEncoder.encodePCM16(samples: [0, 1, -1, 0.5, 2])
        XCTAssertEqual(d.count, 44 + 10)
        XCTAssertEqual(String(decoding: d[0 ..< 4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8 ..< 12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: d[36 ..< 40], as: UTF8.self), "data")
        func u32(_ o: Int) -> UInt32 { d[o ..< o + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        func i16(_ o: Int) -> Int16 { Int16(bitPattern: UInt16(d[o]) | UInt16(d[o + 1]) << 8) }
        XCTAssertEqual(u32(4), 36 + 10)
        XCTAssertEqual(u32(24), 16_000, "サンプルレート")
        XCTAssertEqual(u32(28), 32_000, "バイトレート")
        XCTAssertEqual(u32(40), 10)
        XCTAssertEqual(i16(44), 0)
        XCTAssertEqual(i16(46), 32767)
        XCTAssertEqual(i16(48), -32767)
        XCTAssertEqual(i16(50), 16384)
        XCTAssertEqual(i16(52), 32767, "クリップ")
    }

    // MARK: 録音器（マイクを開かない経路だけ）

    private func recorder(_ status: AVAuthorizationStatus) -> PushToTalkRecorder {
        PushToTalkRecorder(writesFile: false, fileDirectory: FileManager.default.temporaryDirectory, authorization: { status })
    }

    func testStartThrowsWhenMicrophoneDenied() async {
        for (status, expected) in [(AVAuthorizationStatus.denied, PushToTalkRecorder.RecorderError.microphonePermissionDenied),
                                   (.restricted, .microphonePermissionDenied),
                                   (.notDetermined, .microphonePermissionNotDetermined)] {
            let r = recorder(status)
            do {
                try await r.start()
                XCTFail("throw するはず: \(status.rawValue)")
            } catch {
                XCTAssertEqual(error as? PushToTalkRecorder.RecorderError, expected)
            }
            do {
                try await r.prepare()
                XCTFail("prepare も throw するはず")
            } catch {
                XCTAssertEqual(error as? PushToTalkRecorder.RecorderError, expected)
            }
            XCTAssertFalse(r.isRecording)
        }
    }

    func testStopWithoutRecordingThrowsAndCancelIsNoop() async {
        let r = recorder(.denied)
        await r.cancel()
        do {
            _ = try await r.stop()
            XCTFail("録音していなければ throw")
        } catch {
            XCTAssertEqual(error as? PushToTalkRecorder.RecorderError, .notRecording)
        }
    }

    func testLevelsStreamFinishesWhenRecorderIsReleased() async {
        var r: PushToTalkRecorder? = recorder(.denied)
        let stream = await r!.levels()
        r = nil
        var n = 0
        for await _ in stream { n += 1 }
        XCTAssertEqual(n, 0)
    }

    func testMicrophoneStateMapping() {
        XCTAssertEqual(CapturePermissions.microphoneState(from: .authorized), .granted)
        XCTAssertEqual(CapturePermissions.microphoneState(from: .denied), .denied)
        XCTAssertEqual(CapturePermissions.microphoneState(from: .restricted), .denied)
        XCTAssertEqual(CapturePermissions.microphoneState(from: .notDetermined), .notDetermined)
    }

    func testSettingsURLs() {
        XCTAssertEqual(CapturePermissions.settingsURL(for: .microphone).absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        XCTAssertEqual(CapturePermissions.settingsURL(for: .screenRecording).absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertEqual(CapturePermissions.settingsURL(for: .accessibility).absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(CapturePermissions.settingsURL(for: .automation).absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    /// 状態取得はダイアログを出さない API だけを使う（呼んでも安全）。
    func testStatusGettersDoNotPrompt() {
        _ = CapturePermissions.status(.microphone)
        _ = CapturePermissions.status(.screenRecording)
        _ = CapturePermissions.status(.accessibility)
    }
}

private extension Double {
    var float: Float { Float(self) }
}
