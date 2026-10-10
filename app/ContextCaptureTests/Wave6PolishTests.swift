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

// MARK: - 詳細ビューの保存（RecordModifying.modify で 1 トランザクション）

/// `modify` だけを許すストア（`update` を呼んだら失敗させ、get + update に戻っていないことを確かめる）。
final class ModifyOnlyStore: RecordStore, RecordModifying, @unchecked Sendable {
    let inner = TestStore()
    let modifyCalls = Box(0)
    /// modify の直前に「別プロセスの書き込み」を差し込む。
    let beforeModify = Box<(@Sendable (inout ContextRecord) -> Void)?>(nil)

    func insert(_ record: ContextRecord) async throws { try await inner.insert(record) }
    func update(_ record: ContextRecord) async throws { throw CocoaError(.featureUnsupported) }
    func get(id: String) async throws -> ContextRecord? { try await inner.get(id: id) }
    func list(_ filter: InboxFilter) async throws -> [ContextRecord] { try await inner.list(filter) }
    func count(_ filter: InboxFilter) async throws -> Int { try await inner.count(filter) }
    func delete(id: String) async throws { try await inner.delete(id: id) }
    func setEmbedding(id: String, vector: [Float]) async throws { try await inner.setEmbedding(id: id, vector: vector) }
    func search(vector: [Float], limit: Int) async throws -> [SearchHit] { try await inner.search(vector: vector, limit: limit) }
    func writeAttachment(_ data: Data, id: String, kind: AttachmentKind, ext: String, capturedAt: Date) async throws -> String {
        try await inner.writeAttachment(data, id: id, kind: kind, ext: ext, capturedAt: capturedAt)
    }
    func attachmentURL(for relativePath: String) async throws -> URL { try await inner.attachmentURL(for: relativePath) }

    @discardableResult
    func modify(id: String, _ transform: @escaping @Sendable (inout ContextRecord) throws -> Void) async throws -> ContextRecord {
        modifyCalls.update { $0 += 1 }
        let before = beforeModify.get()
        return try await inner.modify(id: id) { r in
            before?(&r)
            try transform(&r)
        }
    }
}

struct NoGuardReview: GuardReviewing {
    func markReviewed(recordID: String) async throws -> ContextRecord { throw CocoaError(.featureUnsupported) }
    func useMaskedImage(recordID: String) async throws -> ContextRecord { throw CocoaError(.featureUnsupported) }
}

@MainActor
final class DetailSaveTests: XCTestCase {
    func testAnnotationAndIntentSavesUseModify() async throws {
        let store = ModifyOnlyStore()
        defer { try? FileManager.default.removeItem(at: store.inner.root) }
        let r = makeWave6Record("元の注釈")
        try await store.insert(r)
        let queue = FakeTriageQueue()
        let vm = DetailViewModel(record: r, store: store, guardReview: NoGuardReview(), triage: queue)

        // 保存の直前に別プロセス（cc-mcp）がメモを足していても、注釈の保存で消えない（同じトランザクションで最新に当てる）。
        store.beforeModify.set { rec in
            if rec.notes.isEmpty { rec.notes.append(Note(author: "claude-code", text: "メモ", at: Date(timeIntervalSince1970: 1_791_000_000))) }
        }
        vm.draftText = "直した注釈"
        await vm.saveAnnotation()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(store.modifyCalls.get(), 1)
        var saved = try await store.get(id: r.id)
        XCTAssertEqual(saved?.annotation.text, "直した注釈")
        XCTAssertEqual(saved?.annotation.edited, true)
        XCTAssertEqual(saved?.notes.count, 1)
        XCTAssertEqual(vm.record.notes.count, 1, "画面の記録も最新になる")
        let edited = await eventually { queue.calls.get().contains(.annotationEdited(r.id)) }
        XCTAssertTrue(edited)

        await vm.setIntent(.research)
        XCTAssertEqual(store.modifyCalls.get(), 2)
        saved = try await store.get(id: r.id)
        XCTAssertEqual(saved?.triage?.intent, .research)
        XCTAssertEqual(saved?.triage?.isManual, true)
    }

    func testMissingRecordIsNotRecreated() async throws {
        let store = ModifyOnlyStore()
        defer { try? FileManager.default.removeItem(at: store.inner.root) }
        let r = makeWave6Record("消える")
        let vm = DetailViewModel(record: r, store: store, guardReview: NoGuardReview())
        vm.draftText = "x"
        await vm.saveAnnotation()
        XCTAssertNotNil(vm.errorMessage)
        let missing = try await store.get(id: r.id)
        XCTAssertNil(missing)
    }
}

private func eventually(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
