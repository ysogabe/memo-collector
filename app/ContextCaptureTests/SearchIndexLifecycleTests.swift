import CCCore
import CoreGraphics
import Foundation
import XCTest

@MainActor
final class SearchIndexLifecycleTests: XCTestCase {
    actor WaitingEmbedder: PreparableEmbedder {
        nonisolated let dimension = 4
        nonisolated let indexSignature = "old"
        var isLoaded: Bool { false }
        private var release: CheckedContinuation<Void, Never>?
        private var entered: [CheckedContinuation<Void, Never>] = []
        func prepareForUse() async throws {
            await withCheckedContinuation { release = $0; let all = entered; entered = []; for waiter in all { waiter.resume() } }
        }
        func waitUntilPreparing() async { if release == nil { await withCheckedContinuation { entered.append($0) } } }
        func finish() { release?.resume(); release = nil }
        func unload() async {}
        func loadDescription() async -> String { "fixture" }
        func embedQuery(_ text: String) async throws -> [Float] { [1,0,0,0] }
        func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] { [1,0,0,0] }
    }

    func testCachedStartupResumesOnlyOnceAndPreparedNoticeDoesNotReinstall() async {
        let store = TestStore(), queue = FakeTriageQueue(), created = Box(0)
        defer { try? FileManager.default.removeItem(at: store.root) }
        let index = SearchIndexMaintainer(embedder: SwitchableEmbedder(dimension: 4), queue: queue, store: store,
            stateURL: store.root.appendingPathComponent("state.json"), makeEmbedder: { _ in
                created.update { $0 += 1 }; return FakePreparableEmbedder(signature: "s")
            })
        await index.activate(imageTokens: 280).value
        XCTAssertEqual(queue.calls.get().filter { $0 == .resumePending }.count, 1)
        await index.modelsPrepared(imageTokens: 280).value
        XCTAssertEqual(created.get(), 1)
        XCTAssertEqual(queue.calls.get().filter { $0 == .resumePending }.count, 2)
    }

    func testFailedEncoderResumesGuardIntentAndModelsPreparedRetries() async {
        let store = TestStore(), queue = FakeTriageQueue(), failing = Box(true)
        defer { try? FileManager.default.removeItem(at: store.root) }
        let index = SearchIndexMaintainer(embedder: SwitchableEmbedder(dimension: 4), queue: queue, store: store,
            stateURL: store.root.appendingPathComponent("state.json"), makeEmbedder: { _ in
                FakePreparableEmbedder(signature: "s", failPrepare: failing.get())
            })
        await index.activate(imageTokens: 280).value
        XCTAssertEqual(index.readiness, .failed)
        XCTAssertEqual(queue.calls.get().filter { $0 == .resumePending }.count, 1)
        failing.set(false)
        await index.modelsPrepared(imageTokens: 280).value
        XCTAssertEqual(index.readiness, .ready)
    }

    func testSettingsChangeDuringPreparationCannotPublishObsoleteSignature() async {
        let store = TestStore(), queue = FakeTriageQueue(), old = WaitingEmbedder()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let state = store.root.appendingPathComponent("state.json")
        let index = SearchIndexMaintainer(embedder: SwitchableEmbedder(dimension: 4), queue: queue, store: store,
            stateURL: state, makeEmbedder: { tokens in
                if tokens == 280 { return old }
                return FakePreparableEmbedder(signature: "new")
            })
        let first = index.activate(imageTokens: 280)
        await old.waitUntilPreparing()
        index.settingsChanged(imageTokens: 70)
        await index.waitForActivation()
        await old.finish(); await first.value
        XCTAssertEqual(index.activeImageTokens, 70)
        XCTAssertEqual(index.readiness, .ready)
        XCTAssertEqual(SearchIndexState.read(from: state)?.indexSignature, "new")
    }
}
