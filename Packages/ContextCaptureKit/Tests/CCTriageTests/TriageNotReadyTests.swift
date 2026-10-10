import CCCore
import CCEmbedding
import CCIntent
import CCStore
import XCTest
@testable import CCTriage

/// Wave 6: モデルの未準備を失敗扱いにしない（`.skipped(.notReady)`）・索引の作り直しの結果報告（`reindexAndWait`）。
final class TriageNotReadyTests: XCTestCase {
    var temp: TempStore!
    var classifier: FakeClassifier!
    var scanner: FakeScanner!
    var embedder: FakeEmbedder!
    var loader: FakeLoader!

    override func setUp() async throws {
        temp = try TempStore()
        classifier = FakeClassifier()
        scanner = FakeScanner()
        embedder = FakeEmbedder()
        loader = FakeLoader()
    }

    private func makeQueue(classifier: (any IntentClassifying & ModelUnloadable)? = nil) -> TriageQueue {
        TriageQueue(store: temp.store, classifier: classifier ?? self.classifier, scanner: scanner, embedder: embedder,
                    screenshots: loader)
    }

    private func embeddedIDs() async throws -> Set<String> {
        try await temp.store.idsWithEmbedding(dimension: 256)
    }

    func testPackageErrorsReportNotReady() {
        XCTAssertTrue(D1IntentError.modelNotFound(URL(fileURLWithPath: "/nonexistent")).isModelNotReady)
        XCTAssertFalse(D1IntentError.emptyInput.isModelNotReady)
        XCTAssertTrue(EmbeddingError.modelFilesMissing(directory: "/x", missing: ["a"]).isModelNotReady)
        XCTAssertFalse(EmbeddingError.predictionFailed("x").isModelNotReady)
        XCTAssertEqual(TriageQueue.outcome(for: FakeNotReady()), .skipped(.notReady))
        XCTAssertEqual(TriageQueue.outcome(for: EmbeddingError.predictionFailed("x")), .failed(TriageQueue.describe(EmbeddingError.predictionFailed("x"))))
        XCTAssertTrue(TriageStepOutcome.skipped(.notReady).isDeferredUntilReady)
        XCTAssertFalse(TriageStepOutcome.failed("x").isDeferredUntilReady)
    }

    /// d1 のファイルが無い（本物の D1IntentClassifier）・埋め込みが準備中 → どちらも skipped(.notReady)。
    /// 何も書かないので resumePending が拾い続け、揃った後に処理される。
    func testNotReadyStepsAreDeferredAndResumedLater() async throws {
        let r = makeRecord()
        try await temp.store.insert(r)
        let missingD1 = D1IntentClassifier(
            modelDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("no-d1-\(UUID().uuidString)"))
        embedder.notReady = true
        let q = makeQueue(classifier: missingD1)
        let events = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let ok = await events.wait { $0.contains(.idle) }
        XCTAssertTrue(ok)
        XCTAssertEqual(events.events.filter { if case .stepFinished = $0 { return true } else { return false } }, [
            .stepFinished(id: r.id, step: .guardScan, outcome: .succeeded),
            .stepFinished(id: r.id, step: .intent, outcome: .skipped(.notReady)),
            .stepFinished(id: r.id, step: .index, outcome: .skipped(.notReady)),
        ])
        let saved = try await temp.store.get(id: r.id)
        XCTAssertNil(saved?.triage)
        var embedded = try await embeddedIDs()
        XCTAssertFalse(embedded.contains(r.id))

        // まだ未準備のまま再開しても拾い続ける（何度でも）。
        let n1 = try await q.resumePending()
        XCTAssertEqual(n1, 1)
        await q.waitUntilIdle()
        let n2 = try await q.resumePending()
        XCTAssertEqual(n2, 1)
        await q.waitUntilIdle()

        // モデルが揃った（分類器はフェイクに、埋め込みは準備完了に）→ 拾って書く。
        embedder.notReady = false
        let ready = makeQueue()
        let n3 = try await ready.resumePending()
        XCTAssertEqual(n3, 1)
        await ready.waitUntilIdle()
        let done = try await temp.store.get(id: r.id)
        XCTAssertEqual(done?.triage?.intent, .todo)
        embedded = try await embeddedIDs()
        XCTAssertTrue(embedded.contains(r.id))
        let again = try await ready.resumePending()
        XCTAssertEqual(again, 0)
    }

    func testReindexAndWaitReportsRecordsThatWereNotIndexed() async throws {
        let a = makeRecord(offset: 0, text: "成功する")
        let b = makeRecord(offset: 1, text: "失敗する")
        let c = makeRecord(offset: 2, text: "消える")
        for r in [a, b, c] { try await temp.store.insert(r) }
        try await temp.store.delete(id: c.id)
        embedder.failTexts = ["失敗する"]
        let q = makeQueue()

        var report = await q.reindexAndWait(ids: [a.id, b.id, c.id, a.id])
        XCTAssertEqual(report, TriageReindexReport(requested: 3, failedIDs: [b.id]), "消えた記録は成功扱い、重複は 1 つ")

        embedder.notReady = true
        report = await q.reindexAndWait(ids: [a.id])
        XCTAssertEqual(report.failedIDs, [a.id], "未準備も索引できていないので失敗側に数える")

        embedder.notReady = false
        embedder.failTexts = []
        report = await q.reindexAndWait(ids: [b.id])
        XCTAssertEqual(report, TriageReindexReport(requested: 1, failedIDs: []))
        let empty = await q.reindexAndWait(ids: [])
        XCTAssertEqual(empty, TriageReindexReport(requested: 0, failedIDs: []))
    }
}
