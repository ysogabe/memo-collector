import CCCore
import Foundation
import XCTest

@MainActor
final class SearchPreparationStatusTests: XCTestCase {
    func testWaitingForWhisperWarmupShowsPreparingOnlyWhenSearchModelExists() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = FakeTriageQueue()
        let index = SearchIndexMaintainer(embedder: SwitchableEmbedder(dimension: 4), queue: queue,
            store: TestStore(), stateURL: root, makeEmbedder: { _ in FakePreparableEmbedder(signature: "s") })
        index.markPreparationPending(imageTokens: 280)
        XCTAssertEqual(index.readiness, .preparing)
        XCTAssertEqual(queue.calls.get(), [])
        let missing = SearchIndexMaintainer(embedder: SwitchableEmbedder(dimension: 4), queue: queue,
            store: TestStore(), stateURL: root, makeEmbedder: { _ in nil })
        missing.markPreparationPending(imageTokens: 280)
        XCTAssertEqual(missing.readiness, .unavailable)
    }
}
