import CCCore
import Foundation
import XCTest
@testable import CCIntent

final class IntentQuestionCandidateTests: XCTestCase {
    func testProductCandidatePreservesQuestionAndRejectsIncompleteDescriptions() throws {
        XCTAssertEqual(try IntentQuestionCandidate.product.validatedQuestion(), D1Questions.intent)
        let invalid = IntentQuestionCandidate(name: "bad", instructions: "説明", descriptions: [.todo: "todo"])
        XCTAssertThrowsError(try invalid.validatedQuestion())
        let roundTrip = try JSONDecoder().decode(IntentQuestionCandidate.self, from: JSONEncoder().encode(IntentQuestionCandidate.product))
        XCTAssertEqual(try roundTrip.validatedQuestion(), D1Questions.intent)
    }
    func testProductCandidateMatchesActualClassifierIntentForward() async throws {
        guard ProcessInfo.processInfo.environment["CC_RUN_INTENT_EVAL"] == "1" else { throw XCTSkip("opt-in real d1 candidate equivalence") }
        guard let directory = try D1TestSupport.modelDirectory() else { throw XCTSkip("prepared d1 required") }
        let classifier = D1IntentClassifier(modelDirectory: directory)
        let normal = try await classifier.probabilities(text: "この関数のテストを書いておいて")
        let candidate = try await classifier.intentProbabilities(text: "この関数のテストを書いておいて")
        for (intent, p) in zip(D1Questions.intentLabels, normal.intent) { XCTAssertEqual(candidate[intent]!, p, accuracy: 0.00001) }
        await classifier.unload()
    }
    func testInvalidCandidateFailsBeforeLoadingModels() async {
        let classifier = D1IntentClassifier(modelDirectory: URL(fileURLWithPath: "/nonexistent-evaluation-model"))
        do { _ = try await classifier.intentProbabilities(text: "test", candidate: .init(name: "bad", instructions: "", descriptions: [:])); XCTFail() }
        catch { XCTAssertTrue(error is IntentQuestionCandidate.CandidateError) }
        let loaded = await classifier.isLoaded
        XCTAssertFalse(loaded)
    }
}
