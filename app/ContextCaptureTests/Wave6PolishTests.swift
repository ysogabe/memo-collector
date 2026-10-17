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

    /// degraded のとき、索引できなかった記録（failed_ids）の古いベクトルはベクトル検索の結果に混ぜない。
    /// 文字の一致で見つかるものだけを後ろに足す。
    func testDegradedSearchExcludesFailedRecordsStaleVectors() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let good = makeWave6Record("ビデオ会議", at: 0)
        let staleMatch = makeWave6Record("会議の議事録", at: -1)   // 索引に失敗。文字では一致する
        let staleOther = makeWave6Record("買い物リスト", at: -2)  // 索引に失敗。文字でも一致しない
        for r in [good, staleMatch, staleOther] { try await store.insert(r) }
        try await store.setEmbedding(id: good.id, vector: [0.5, 0, 0, 0])
        // 古いシグネチャのベクトル（クエリとの内積が大きく、外さないと上位に来る）
        try await store.setEmbedding(id: staleMatch.id, vector: [1, 0, 0, 0])
        try await store.setEmbedding(id: staleOther.id, vector: [0.9, 0, 0, 0])
        let embedder = SwitchableEmbedder(dimension: 4)
        await embedder.install(FakePreparableEmbedder(signature: "s"))
        let failed: Set<String> = [staleMatch.id, staleOther.id]
        let service = EmbeddingSearchService(embedder: embedder, store: store, readiness: { .degraded(failed: 2) },
                                             degradedFailedIDs: { failed })
        let response = try await service.searchWithNotice("会議", limit: 5)
        XCTAssertEqual(response.hits.map(\.record.id), [good.id, staleMatch.id],
                       "古いベクトルでは出さず、文字の一致したものだけ後ろに足す")
        XCTAssertFalse(response.hits.contains { $0.record.id == staleOther.id })
        XCTAssertEqual(response.notice, EmbeddingSearchService.degradedNotice(failed: 2))

        // limit が埋まっていれば補わない
        let one = try await service.searchWithNotice("会議", limit: 1)
        XCTAssertEqual(one.hits.map(\.record.id), [good.id])

        // ready のときは外さない（failed_ids は degraded のときだけ意味を持つ）
        let ready = EmbeddingSearchService(embedder: embedder, store: store, readiness: { .ready }, degradedFailedIDs: { [] })
        let all = try await ready.searchWithNotice("会議", limit: 5)
        XCTAssertEqual(all.hits.first?.record.id, staleMatch.id)
    }

    /// 作り直しが degraded で終わったら、maintainer は failed_ids を持つ。ready になったら空にする。
    func testMaintainerExposesDegradedFailedIDs() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = makeWave6Record("a", at: 0), b = makeWave6Record("b", at: -1)
        for r in [a, b] { try await store.insert(r) }
        let queue = FakeTriageQueue()
        queue.failing.set([b.id: 2])
        let m = make(store: store, queue: queue)
        await m.activate(imageTokens: 280).value
        XCTAssertEqual(m.readiness, .degraded(failed: 1))
        XCTAssertEqual(m.degradedFailedIDs, [b.id])
        // 次の起動でやり直しが成功 → ready、除外も消える
        await m.activate(imageTokens: 280).value
        XCTAssertEqual(m.readiness, .ready)
        XCTAssertEqual(m.degradedFailedIDs, [])
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

    /// 注釈を編集中に意図を変えても、未保存の下書きは消えない（保存されるのは意図だけ）。
    func testIntentChangeKeepsUnsavedDraft() async throws {
        let store = ModifyOnlyStore()
        defer { try? FileManager.default.removeItem(at: store.inner.root) }
        let r = makeWave6Record("元の注釈")
        try await store.insert(r)
        let vm = DetailViewModel(record: r, store: store, guardReview: NoGuardReview())
        vm.draftText = "編集中の注釈"
        await vm.setIntent(.research)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.draftText, "編集中の注釈", "意図の保存で下書きを保存値に戻さない")
        XCTAssertTrue(vm.isAnnotationChanged)
        var saved = try await store.get(id: r.id)
        XCTAssertEqual(saved?.annotation.text, "元の注釈", "下書きは保存されない")
        XCTAssertEqual(saved?.triage?.intent, .research)

        // 完了でも同じ
        await vm.markDone()
        XCTAssertEqual(vm.draftText, "編集中の注釈")
        saved = try await store.get(id: r.id)
        XCTAssertEqual(saved?.status, .done)
        XCTAssertEqual(saved?.annotation.text, "元の注釈")

        // 注釈の保存のときは保存値に揃う（変更なしになる）
        await vm.saveAnnotation()
        XCTAssertEqual(vm.draftText, "編集中の注釈")
        XCTAssertFalse(vm.isAnnotationChanged)
        saved = try await store.get(id: r.id)
        XCTAssertEqual(saved?.annotation.text, "編集中の注釈")
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

/// 検索結果を固定で返すだけの検索（キーボード選択のテスト用）。
private struct FixedSearch: SearchServing {
    var hits: [SearchHit]
    /// true の間は検索が失敗する。
    var failing = Box(false)
    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        if failing.get() { throw CocoaError(.fileReadUnknown) }
        return hits
    }
}

// Inbox のキーボード選択（検索欄の ↓ から一覧へ入るとき、未選択なら先頭を選ぶ）と、検索欄の Enter の振り分け。
@MainActor
final class InboxKeyboardSelectionTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_791_000_000 + 10)

    /// 新しい順に a, b（今日）、c（2 日前）、d（4 日前）。日付セクションは 3 つ。
    private func makeRecords() -> [ContextRecord] {
        [makeWave6Record("a", at: 0), makeWave6Record("b", at: -60),
         makeWave6Record("c", at: -2 * day), makeWave6Record("d", at: -4 * day)]
    }

    private func makeVM(records: [ContextRecord], hits: [SearchHit] = [],
                        search: FixedSearch? = nil) async throws -> InboxViewModel {
        let store = TestStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: store.root) }
        for r in records { try await store.insert(r) }
        let vm = InboxViewModel(store: store, search: search ?? FixedSearch(hits: hits), now: { [now] in now })
        await vm.load()
        return vm
    }

    func testSelectFirstIfNeededPicksFirstWhenNothingSelected() async throws {
        let vm = try await makeVM(records: makeRecords())
        let rows = vm.visibleRecords
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(vm.sections.count, 3)
        XCTAssertNil(vm.selection)
        vm.selectFirstIfNeeded()
        XCTAssertEqual(vm.selection, rows[0].id)
    }

    func testStaleSelectionFallsBackToFirst() async throws {
        let vm = try await makeVM(records: makeRecords())
        vm.selection = "gone"
        vm.selectFirstIfNeeded()
        XCTAssertEqual(vm.selection, vm.visibleRecords[0].id)
    }

    func testEmptyListKeepsNoSelection() async throws {
        let vm = try await makeVM(records: [])
        vm.selectFirstIfNeeded()
        XCTAssertNil(vm.selection)
    }

    func testSelectFirstIfNeededKeepsExistingSelection() async throws {
        let vm = try await makeVM(records: makeRecords())
        let rows = vm.visibleRecords
        vm.selectFirstIfNeeded()
        XCTAssertEqual(vm.selection, rows[0].id)
        vm.selection = rows[2].id
        vm.selectFirstIfNeeded()
        XCTAssertEqual(vm.selection, rows[2].id)
    }

    func testSelectFirstIfNeededUsesSearchResultsOrder() async throws {
        let records = makeRecords()
        // 検索結果は c, a の順（スコア順）。先頭は一覧の先頭ではなく、この順の先頭。
        let hits = [SearchHit(record: records[2], score: 0.9), SearchHit(record: records[0], score: 0.5)]
        let vm = try await makeVM(records: records, hits: hits)
        vm.query = "x"
        await vm.runSearch()
        vm.selection = nil
        vm.selectFirstIfNeeded()
        XCTAssertEqual(vm.selection, records[2].id)
    }

    // MARK: 検索欄の Enter

    func testSubmitSearchesWhenNothingSearchedYet() async throws {
        let vm = try await makeVM(records: makeRecords())
        vm.selection = vm.visibleRecords[0].id
        vm.query = "会議"
        XCTAssertEqual(vm.submitAction(), .search)
    }

    func testSubmitOpensSelectionWhenQueryIsAlreadySearched() async throws {
        let records = makeRecords()
        let hits = [SearchHit(record: records[2], score: 0.9), SearchHit(record: records[0], score: 0.5)]
        let vm = try await makeVM(records: records, hits: hits)
        vm.query = "  会議 "
        await vm.runSearch()
        XCTAssertEqual(vm.submitAction(), .open(records[2].id))
        vm.selection = records[0].id
        XCTAssertEqual(vm.submitAction(), .open(records[0].id))
    }

    func testSubmitSearchesAgainWhenQueryChangedOrSelectionMissing() async throws {
        let records = makeRecords()
        let hits = [SearchHit(record: records[2], score: 0.9)]
        let vm = try await makeVM(records: records, hits: hits)
        vm.query = "会議"
        await vm.runSearch()
        vm.query = "会議 資料"
        XCTAssertEqual(vm.submitAction(), .search)
        vm.query = "会議"
        vm.selection = nil
        XCTAssertEqual(vm.submitAction(), .search)
        vm.selection = "gone"
        XCTAssertEqual(vm.submitAction(), .search)
    }

    func testSubmitSearchesAgainWhenLastSearchFailed() async throws {
        let records = makeRecords()
        let search = FixedSearch(hits: [SearchHit(record: records[2], score: 0.9)])
        let vm = try await makeVM(records: records, search: search)
        vm.query = "会議"
        await vm.runSearch()
        XCTAssertEqual(vm.submitAction(), .open(records[2].id))
        // 再検索（scope 切替など）が失敗すると一覧は隠れる。古い結果が残っていても開かない。
        search.failing.set(true)
        await vm.runSearch()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.submitAction(), .search)
    }

    func testSubmitWithEmptyQueryIsSearch() async throws {
        let vm = try await makeVM(records: makeRecords())
        vm.selection = vm.visibleRecords[0].id
        vm.query = "   "
        XCTAssertEqual(vm.submitAction(), .search)
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
