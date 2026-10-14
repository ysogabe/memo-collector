import CCCore
import XCTest

final class IntentEvaluationTests: XCTestCase {
    func probabilities(_ winner: Intent, _ confidence: Double) -> [Intent: Double] {
        Dictionary(uniqueKeysWithValues: Intent.allCases.map { ($0, $0 == winner ? confidence : (1-confidence)/4) })
    }
    func testCoverageAndAcceptedAccuracyAreSeparate() throws {
        let rows = [LabeledIntentPrediction(truth: .note, probabilities: probabilities(.note, 0.8)),
                    LabeledIntentPrediction(truth: .note, probabilities: probabilities(.research, 0.6))]
        let conservative = try IntentEvaluation.evaluate(rows, threshold: 0.7)
        XCTAssertEqual(conservative.coverage, 0.5)
        XCTAssertEqual(conservative.accuracy, 1)
        let permissive = try IntentEvaluation.evaluate(rows, threshold: 0.5)
        XCTAssertEqual(permissive.coverage, 1)
        XCTAssertEqual(permissive.accuracy, 0.5)
    }
    func testNoAcceptanceHasNoAccuracyAndThresholdBoundaryIsInclusive() throws {
        let row = LabeledIntentPrediction(truth: .note, probabilities: probabilities(.note, 0.7))
        XCTAssertEqual(try IntentEvaluation.evaluate([row], threshold: 0.7).classified, 1)
        XCTAssertNil(try IntentEvaluation.evaluate([row], threshold: 0.8).accuracy)
    }
    func testMissingOrInvalidDistributionsAndNoGoldCannotPass() {
        for probs in [[Intent.note: 0.9], probabilities(.note, Double.nan)] {
            XCTAssertThrowsError(try IntentEvaluation.evaluate([.init(truth: .note, probabilities: probs)], threshold: 0.7))
        }
        XCTAssertThrowsError(try IntentEvaluation.evaluate([], threshold: 0.7))
        XCTAssertThrowsError(try IntentEvaluation.evaluate([.init(truth: .note, probabilities: probabilities(.note, 0.8))], threshold: 2))
    }
}
