import XCTest

final class CaptureReplayMetricsTests: XCTestCase {
    func testConfigurationDefaultsAndRejectedOptions() throws {
        let defaults = try CaptureReplayConfiguration(environment: [:])
        XCTAssertEqual(defaults.encoderName, "cpuAndNeuralEngine")
        XCTAssertEqual(defaults.quietMilliseconds, 0)
        for env in [["CC_CAPTURE_STT_ENCODER": "typo"], ["CC_CAPTURE_STT_DECODER": "cpu"],
                    ["CC_CAPTURE_QUIET_MS": "-1"], ["CC_CAPTURE_QUIET_MS": "2001"],
                    ["CC_CAPTURE_CONDITION_ORDER": "with_triage,with_triage"]] {
            XCTAssertThrowsError(try CaptureReplayConfiguration(environment: env))
        }
        let candidate = try CaptureReplayConfiguration(environment: ["CC_CAPTURE_STT_ENCODER":"gpu", "CC_CAPTURE_QUIET_MS":"750", "CC_CAPTURE_CONDITION_ORDER":"with_triage,without_triage"])
        XCTAssertEqual(candidate.encoderName, "cpuAndGPU")
        XCTAssertEqual(candidate.conditionOrder.first, "with_triage")
    }
    func testCERMatchesExistingFixtureScoringDefinition() {
        XCTAssertEqual(CaptureReplayMetrics.characterErrorRate(reference: "これHermesのアダプタ。", hypothesis: "これHRMESのアダプタ、"), 1.0/13, accuracy: 1e-9)
        XCTAssertEqual(CaptureReplayMetrics.characterErrorRate(reference: "Claude Code", hypothesis: "CLAUDE CODE。"), 0)
        XCTAssertEqual(CaptureReplayMetrics.characterErrorRate(reference: "", hypothesis: "あ"), 1)
    }
}
