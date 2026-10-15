import XCTest
@testable import CCCore

final class IntentDecisionTests: XCTestCase {
    func testAboveThresholdIsClassified() {
        let d = resolveIntent(probabilities: [.code: 0.84, .todo: 0.1, .note: 0.06])
        XCTAssertEqual(d.intent, .code)
        XCTAssertEqual(d.confidence, 0.84)
    }

    func testExactlyThresholdIsClassified() {
        let d = resolveIntent(probabilities: [.todo: 0.6, .note: 0.4])
        XCTAssertEqual(d.intent, .todo)
    }

    func testBelowThresholdIsUnclassifiedButKeepsConfidence() {
        let d = resolveIntent(probabilities: [.research: 0.5999, .note: 0.4001])
        XCTAssertNil(d.intent)
        XCTAssertEqual(d.confidence, 0.5999)
    }

    func testShortReadingNotesAtNewDefaultThreshold() {
        // 実マイク20件の最大確率2群。60%台のtodoは採用し、50%台のnoteは未分類のまま。
        let todo = TriageResult(probabilities: [.todo: 0.6068, .note: 0.2232, .research: 0.1441, .code: 0.0172, .schedule: 0.0087],
                                datetimeProbability: 0.2, model: "d1")
        XCTAssertEqual(todo.intent, .todo)
        XCTAssertEqual(todo.intentConfidence, 0.6068)
        let uncertain = TriageResult(probabilities: [.note: 0.5749, .todo: 0.3952, .research: 0.0174, .code: 0.0072, .schedule: 0.0053],
                                     datetimeProbability: 0.2, model: "d1")
        XCTAssertNil(uncertain.intent)
        XCTAssertEqual(uncertain.intentConfidence, 0.5749)
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
