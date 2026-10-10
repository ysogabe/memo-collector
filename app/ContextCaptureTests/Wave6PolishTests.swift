import CCCore
import CCTriage
import CoreGraphics
import Foundation
import XCTest

// Wave 6 polish: 索引の作り直しの一部失敗（degraded）・未準備の扱い。

private func makeWave6Record(_ text: String, at offset: TimeInterval = 0) -> ContextRecord {
    ContextRecord(capturedAt: Date(timeIntervalSince1970: 1_791_000_000 + offset),
                  app: AppInfo(name: "Terminal", bundleID: "com.apple.Terminal"),
                  annotation: Annotation(text: text, sttEngine: "whisper"))
}

@MainActor
final class SearchIndexDegradedTests: XCTestCase {
    private var dir: URL!
    private var stateURL: URL { SearchIndexState.url(dataRoot: dir) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-index6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func make(store: TestStore, queue: FakeTriageQueue) -> SearchIndexMaintainer {
        SearchIndexMaintainer(embedder: SwitchableEmbedder(dimension: 4), queue: queue, store: store, stateURL: stateURL) { tokens in
            FakePreparableEmbedder(signature: "sig/img\(tokens)")
        }
    }

    /// 1 件だけ索引できない（やり直しでも失敗）→ ready にしない。状態ファイルは degraded + failed_ids。
    func testPartialFailureIsDegradedNotReady() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = makeWave6Record("a", at: 0), b = makeWave6Record("b", at: -1)
        for r in [a, b] { try await store.insert(r) }
        let queue = FakeTriageQueue()
        queue.failing.set([b.id: 2])  // 1 回目とやり直しの両方で失敗
        let m = make(store: store, queue: queue)
        var seen: [SearchReadiness] = []
        m.onReadinessChange = { seen.append($0) }

        await m.activate(imageTokens: 280).value
        XCTAssertEqual(m.readiness, .degraded(failed: 1))
        XCTAssertEqual(seen, [.preparing, .rebuilding, .degraded(failed: 1)])
        XCTAssertEqual(queue.reindexed, [a.id, b.id, b.id], "失敗分は 1 回だけその場でやり直す")
        let state = try XCTUnwrap(SearchIndexState.read(from: stateURL))
        XCTAssertEqual(state.status, .degraded)
        XCTAssertEqual(state.failedIDs, [b.id])
        XCTAssertEqual(state.indexSignature, "sig/img280")
        XCTAssertNotNil(SearchReadiness.degraded(failed: 1).menuText)
    }

    /// 一時的な失敗（やり直しで成功）なら ready。
    func testTransientFailureIsRetriedOnceThenReady() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = makeWave6Record("a")
        try await store.insert(a)
        let queue = FakeTriageQueue()
        queue.failing.set([a.id: 1])
        let m = make(store: store, queue: queue)
        await m.activate(imageTokens: 280).value
        XCTAssertEqual(m.readiness, .ready)
        XCTAssertEqual(queue.reindexed, [a.id, a.id])
        let state = try XCTUnwrap(SearchIndexState.read(from: stateURL))
        XCTAssertEqual(state.status, .ready)
        XCTAssertNil(state.failedIDs)
    }

    /// 次の起動: 同じシグネチャで degraded なら、失敗した記録だけやり直す（全件はやり直さない）。成功すれば ready。
    func testDegradedRetriesOnlyFailedRecordsOnNextActivation() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = makeWave6Record("a", at: 0), b = makeWave6Record("b", at: -1)
        for r in [a, b] { try await store.insert(r) }
        try SearchIndexState(indexSignature: "sig/img280", imageTokens: 280, dimension: 4, status: .degraded,
                             updatedAt: Date(), failedIDs: [b.id]).write(to: stateURL)
        let queue = FakeTriageQueue()
        let m = make(store: store, queue: queue)
        await m.activate(imageTokens: 280).value
        XCTAssertEqual(queue.reindexed, [b.id])
        XCTAssertTrue(queue.calls.get().contains(.resumePending))
        XCTAssertEqual(m.readiness, .ready)
        XCTAssertEqual(SearchIndexState.read(from: stateURL)?.status, .ready)
    }

    /// シグネチャが変わったら degraded の残りではなく全件を作り直す。
    func testDegradedWithOtherSignatureRebuildsAll() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = makeWave6Record("a", at: 0), b = makeWave6Record("b", at: -1)
        for r in [a, b] { try await store.insert(r) }
        try SearchIndexState(indexSignature: "sig/img70", imageTokens: 70, dimension: 4, status: .degraded,
                             updatedAt: Date(), failedIDs: [b.id]).write(to: stateURL)
        let queue = FakeTriageQueue()
        let m = make(store: store, queue: queue)
        await m.activate(imageTokens: 280).value
        XCTAssertEqual(queue.reindexed, [a.id, b.id])
        XCTAssertEqual(m.readiness, .ready)
    }

    /// degraded のときアプリは見た目での検索を使い、出ないことがある旨を添える。
    func testDegradedSearchUsesVectorWithNotice() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = makeWave6Record("ビデオ会議")
        try await store.insert(a)
        try await store.setEmbedding(id: a.id, vector: [1, 0, 0, 0])
        let embedder = SwitchableEmbedder(dimension: 4)
        await embedder.install(FakePreparableEmbedder(signature: "s"))
        let service = EmbeddingSearchService(embedder: embedder, store: store, readiness: { .degraded(failed: 3) })
        let response = try await service.searchWithNotice("会議", limit: 5)
        XCTAssertEqual(response.hits.map(\.record.id), [a.id])
        XCTAssertEqual(response.notice, EmbeddingSearchService.degradedNotice(failed: 3))
    }

    /// 本物の TriageQueue: 埋め込みが準備中（EmbeddingNotReady）の索引ステップは失敗ではなく後回し、
    /// reindexAll は索引できなかったものとして返す（作り直しを ready にしない）。
    func testEmbeddingNotReadyIsDeferredInRealQueue() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = makeWave6Record("a")
        try await store.insert(a)
        XCTAssertTrue(EmbeddingNotReady().isModelNotReady)
        let embedder = SwitchableEmbedder(dimension: 4)  // install 前 = 未準備
        let queue = TriageQueue(store: store, classifier: FakeClassifier(), scanner: FakeScanner(), embedder: embedder,
                                screenshots: FakeScreenshotLoader())
        let events = await queue.events()
        let failed = await queue.reindexAll(ids: [a.id])
        XCTAssertEqual(failed, [a.id])
        var outcome: TriageStepOutcome?
        for await e in events {
            if case let .stepFinished(_, .index, o) = e { outcome = o; break }
        }
        XCTAssertEqual(outcome, .skipped(.notReady))

        await embedder.install(FakePreparableEmbedder(signature: "s"))
        let again = await queue.reindexAll(ids: [a.id])
        XCTAssertEqual(again, [])
        XCTAssertEqual(store.embeddings.get()[a.id], [1, 0, 0, 0])
    }
}
