import XCTest
@testable import CCCore

final class IntentDecisionTests: XCTestCase {
    func testAboveThresholdIsClassified() {
        let d = resolveIntent(probabilities: [.code: 0.84, .todo: 0.1, .note: 0.06])
        XCTAssertEqual(d.intent, .code)
        XCTAssertEqual(d.confidence, 0.84)
    }

    func testExactlyThresholdIsClassified() {
        let d = resolveIntent(probabilities: [.todo: 0.7, .note: 0.3])
        XCTAssertEqual(d.intent, .todo)
    }

    func testBelowThresholdIsUnclassifiedButKeepsConfidence() {
        let d = resolveIntent(probabilities: [.research: 0.6999, .note: 0.3001])
        XCTAssertNil(d.intent)
        XCTAssertEqual(d.confidence, 0.6999)
    }

    func testEmptyProbabilities() {
        let d = resolveIntent(probabilities: [:])
        XCTAssertNil(d.intent)
        XCTAssertEqual(d.confidence, 0)
    }

    func testTieBreaksByCaseOrder() {
        XCTAssertEqual(resolveIntent(probabilities: [.schedule: 0.5, .todo: 0.5], threshold: 0.5).intent, .todo)
    }

    func testCustomThreshold() {
        XCTAssertEqual(resolveIntent(probabilities: [.note: 0.55], threshold: 0.5).intent, .note)
    }

    func testTriageResultFromProbabilitiesKeepsDistribution() {
        let probs: [Intent: Double] = [.schedule: 0.4, .todo: 0.35, .note: 0.25]
        let t = TriageResult(probabilities: probs, datetimeProbability: 0.5, model: "d1")
        XCTAssertNil(t.intent)
        XCTAssertTrue(t.isUnclassified)
        XCTAssertEqual(t.intentConfidence, 0.4)
        XCTAssertEqual(t.intentProbabilities, probs)
        XCTAssertTrue(t.mentionsDatetime, "0.5 ちょうどは言及あり")
        XCTAssertFalse(TriageResult(probabilities: probs, datetimeProbability: 0.49, model: "d1").mentionsDatetime)
    }
}
