import XCTest
@testable import CCSTT

/// 無音判定の閾値を fixtures と合成音で固定する。
final class SpeechGateTests: XCTestCase {
    let gate = SpeechGate()
    let sr = 16_000

    /// 決定的な疑似乱数の白色雑音（振幅は RMS が `dbfs` になるよう調整）。
    func noise(seconds: Double, dbfs: Float, seed: UInt64 = 42) -> [Float] {
        var state = seed
        let n = Int(seconds * Double(sr))
        let rms = pow(10, dbfs / 20)
        // 一様分布 [-1, 1) の RMS は 1/√3
        let scale = rms * Float(3).squareRoot()
        return (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(state >> 40) / Float(1 << 24) * 2 - 1
            return u * scale
        }
    }

    func sine(seconds: Double, amplitude: Float, hz: Float = 220) -> [Float] {
        (0..<Int(seconds * Double(sr))).map { amplitude * sin(2 * .pi * hz * Float($0) / Float(sr)) }
    }

    func testEmptyAndShortInputsAreTooShort() {
        XCTAssertEqual(gate.rejectionReason(for: []), .tooShort)
        XCTAssertEqual(gate.rejectionReason(for: sine(seconds: 0.29, amplitude: 0.3)), .tooShort)
    }

    func testDigitalSilenceIsSilent() {
        XCTAssertEqual(gate.rejectionReason(for: Array(repeating: 0, count: sr * 2)), .silent)
        XCTAssertEqual(gate.analyze(Array(repeating: 0, count: sr)).peakFrameDBFS, -200)
    }

    func testRoomNoiseIsSilent() {
        // マイクの環境雑音相当（-60 / -50 dBFS）は無音
        XCTAssertEqual(gate.rejectionReason(for: noise(seconds: 3, dbfs: -60)), .silent)
        XCTAssertEqual(gate.rejectionReason(for: noise(seconds: 3, dbfs: -50)), .silent)
    }

    func testBriefClickIsSilent() {
        // 雑音の中に 0.1 秒だけ大きな音（キーを押した音など）→ 発話フレームが 0.15 秒に届かない
        var s = noise(seconds: 2, dbfs: -60)
        let click = sine(seconds: 0.1, amplitude: 0.3)
        s.replaceSubrange(8000..<(8000 + click.count), with: click)
        XCTAssertEqual(gate.rejectionReason(for: s), .silent)
    }

    func testShortUtteranceInNoisePasses() {
        // 雑音の中に 0.3 秒の -30 dBFS 程度の音（短い「はい」相当）
        var s = noise(seconds: 1, dbfs: -60)
        let voice = sine(seconds: 0.3, amplitude: 0.045)
        s.replaceSubrange(4000..<(4000 + voice.count), with: voice)
        XCTAssertNil(gate.rejectionReason(for: s))
    }

    func testAllFixturesPassWithMargin() throws {
        let captures = try STTTestSupport.loadCaptures()
        XCTAssertEqual(captures.count, 30)
        for c in captures {
            let samples = try STTTestSupport.loadWav(STTTestSupport.audioURL(id: c.id))
            let a = gate.analyze(samples)
            XCTAssertNil(gate.rejectionReason(for: samples), "c\(c.id)")
            // 余裕: 実音声の発話フレームは閾値の 10 倍（1.5 秒）以上ある
            XCTAssertGreaterThan(a.activeDuration, 1.5, "c\(c.id)")
            // 音量を 1/10（-20dB）に落としても通る
            XCTAssertNil(gate.rejectionReason(for: samples.map { $0 * 0.1 }), "c\(c.id) -20dB")
        }
    }

    func testFixtureTrimmedTo0_2sIsTooShort() throws {
        let samples = try STTTestSupport.loadWav(STTTestSupport.audioURL(id: 1))
        XCTAssertEqual(gate.rejectionReason(for: Array(samples.prefix(3200))), .tooShort)
    }
}
