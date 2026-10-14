import XCTest
@testable import SearchEvaluation
final class MetricsTests: XCTestCase {
    func testMultipleAnswersAreRecallNotHitRateAndDuplicatesDoNotConsumeRank() {
        let m = Metrics.evaluate(rankedIDs: ["wrong", "a", "a", "b"], relevant: [Relevant("a", grade: 2), Relevant("b"), Relevant("c")])
        XCTAssertEqual(m.recall?["1"], 0)
        XCTAssertEqual(m.recall?["3"], 2.0 / 3.0)
        XCTAssertEqual(m.hitRate?["3"], 1)
        XCTAssertEqual(m.reciprocalRank, 0.5)
        let dcg = 3 / log2(3.0) + 1 / log2(4.0)
        let ideal = 3 + 1 / log2(3.0) + 1 / log2(4.0)
        XCTAssertEqual(m.ndcg?["3"] ?? -1, dcg / ideal, accuracy: 1e-12)
    }
    func testNoAnswerIsSeparateFromRecallAndMRR() {
        let empty = Metrics.evaluate(rankedIDs: [], relevant: [])
        XCTAssertNil(empty.recall); XCTAssertNil(empty.reciprocalRank); XCTAssertTrue(empty.emptyResult)
        XCTAssertFalse(Metrics.evaluate(rankedIDs: ["wrong"], relevant: []).emptyResult)
        XCTAssertEqual(Metrics.evaluate(rankedIDs: [], relevant: [Relevant("a")]).reciprocalRank, 0)
    }
    func testNearestRankAndEmptyPercentiles() {
        XCTAssertNil(Metrics.percentile([], 0.95))
        XCTAssertEqual(Metrics.percentile([1,2,3,4,5], 0.5), 3)
        XCTAssertEqual(Metrics.percentile([1,2,3,4,5], 0.95), 5)
    }
}
