import CCCore
import CCTriage
import CoreGraphics
import Foundation
import ImageIO
import XCTest

// M2 / M3 の配線（トリアージ・ガードの確認・検索・索引の作り直し・モデル準備）のテスト。
// 本物のモデル・権限には触らない（埋め込み・分類器・スキャナはフェイク）。

// MARK: - フェイク

/// 呼ばれた順を残すキュー。
final class FakeTriageQueue: TriageQueuing, @unchecked Sendable {
    enum Call: Hashable {
        case enqueue(String), annotationEdited(String), reindex(String), resumePending
    }

    let calls = Box<[Call]>([])
    let resumeCount = Box(0)

    func enqueue(id: String) async { calls.update { $0.append(.enqueue(id)) } }
    func annotationEdited(id: String) async { calls.update { $0.append(.annotationEdited(id)) } }
    func reindex(id: String) async { calls.update { $0.append(.reindex(id)) } }
    func resumePending() async throws -> Int {
        calls.update { $0.append(.resumePending) }
        return resumeCount.get()
    }
    func waitUntilIdle() async {}

    var reindexed: [String] { calls.get().compactMap { if case let .reindex(id) = $0 { return id } else { return nil } } }
}

/// 準備が要る埋め込みのフェイク。ベクトルはテキストの長さから決まる 4 次元。
actor FakePreparableEmbedder: PreparableEmbedder {
    nonisolated let dimension = 4
    nonisolated let indexSignature: String
    let failPrepare: Bool
    let failQuery: Bool
    private(set) var prepared = false
    private(set) var unloaded = false
    var isLoaded: Bool { prepared && !unloaded }

    init(signature: String, failPrepare: Bool = false, failQuery: Bool = false) {
        indexSignature = signature
        self.failPrepare = failPrepare
        self.failQuery = failQuery
    }

    func prepareForUse() async throws {
        if failPrepare { throw CocoaError(.fileReadCorruptFile) }
        prepared = true
    }

    func unload() async { unloaded = true }
    func loadDescription() async -> String { isLoaded ? "loaded" : "-" }

    func embedQuery(_ text: String) async throws -> [Float] {
        if failQuery { throw CocoaError(.fileReadUnknown) }
        return [1, 0, 0, 0]
    }

    func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] {
        [1, 0, 0, 0]
    }
}

/// d1 のフェイク。
final class FakeClassifier: IntentClassifying, ModelUnloadable, @unchecked Sendable {
    let calls = Box(0)
    func classify(text: String) async throws -> TriageResult {
        calls.update { $0 += 1 }
        return TriageResult(intent: .code, intentConfidence: 0.9, mentionsDatetime: false, model: "fake-d1")
    }
    func unload() async {}
    var isLoaded: Bool { get async { false } }
}

struct FakeScanner: SecretScanning {
    func scan(image: CGImage) async throws -> [SecretFinding] { [] }
}

struct FakeScreenshotLoader: ScreenshotLoading {
    func loadScreenshot(relativePath: String) async throws -> CGImage { TestImages.solid() }
}

extension TestStore: RecordModifying, EmbeddingPresenceChecking {}

private func makeRecord(_ text: String, at offset: TimeInterval = 0, title: String? = nil) -> ContextRecord {
    ContextRecord(capturedAt: Date(timeIntervalSince1970: 1_791_000_000 + offset),
                  app: AppInfo(name: "Terminal", bundleID: "com.apple.Terminal"),
                  window: WindowInfo(title: title, frame: nil),
                  annotation: Annotation(text: text, sttEngine: "whisper"))
}

private struct MissingRecord: Error {}

private func fetch(_ store: TestStore, _ id: String) async throws -> ContextRecord {
    guard let r = try await store.get(id: id) else { throw MissingRecord() }
    return r
}

/// 条件が満たされるまで待つ（Task で投げた依頼の到着待ち）。
private func eventually(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - トリアージの配線

@MainActor
final class TriageWiringTests: XCTestCase {
    func testSavedAndEditedRecordsGoToQueue() async {
        let queue = FakeTriageQueue()
        let wiring = TriageWiring(queue: queue)
        wiring.recordSaved(id: "A")
        wiring.annotationEdited(id: "B")
        let arrived = await eventually { queue.calls.get().count == 2 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(Set(queue.calls.get()), [.enqueue("A"), .annotationEdited("B")])
    }

    func testRefreshesInboxOnlyWhenVisibleStepWrote() {
        let wiring = TriageWiring(queue: FakeTriageQueue())
        var refreshed = 0
        wiring.onRecordsChanged = { refreshed += 1 }
        // 索引だけ書いた → 画面は変わらないので知らせない（作り直しで何百回も読み直さない）
        wiring.handle(.stepFinished(id: "A", step: .index, outcome: .succeeded))
        wiring.handle(.recordFinished(id: "A"))
        XCTAssertEqual(refreshed, 0)
        // 意図を書いた → 知らせる
        wiring.handle(.stepFinished(id: "B", step: .guardScan, outcome: .failed("X")))
        wiring.handle(.stepFinished(id: "B", step: .intent, outcome: .succeeded))
        wiring.handle(.recordFinished(id: "B"))
        XCTAssertEqual(refreshed, 1)
        // ガードを書いた → 知らせる
        wiring.handle(.stepFinished(id: "C", step: .guardScan, outcome: .succeeded))
        wiring.handle(.recordFinished(id: "C"))
        XCTAssertEqual(refreshed, 2)
        // スキップだけ → 知らせない
        wiring.handle(.stepFinished(id: "D", step: .intent, outcome: .skipped(.manuallyEdited)))
        wiring.handle(.recordFinished(id: "D"))
        XCTAssertEqual(refreshed, 2)
    }

    func testClassifierUnloadedIsForwarded() {
        let wiring = TriageWiring(queue: FakeTriageQueue())
        var unloaded = false
        wiring.onClassifierUnloaded = { unloaded = true }
        wiring.handle(.classifierUnloaded)
        XCTAssertTrue(unloaded)
    }

    func testManualIntentUsesTriageResultManual() {
        var r = makeRecord("このissueを直す")
        r.triage = TriageResult(intent: .todo, intentConfidence: 0.8, mentionsDatetime: true, datetimeProbability: 0.9,
                                model: "LiquidAI/d1-3B@051bcc4+mlx-q8")
        RecordEdits.setManualIntent(.code, on: &r)
        XCTAssertEqual(r.triage, TriageResult.manual(intent: .code, mentionsDatetime: true))
        XCTAssertEqual(r.triage?.model, TriageMarkers.manualModel)
        XCTAssertTrue(r.triage?.isManual == true)

        var empty = makeRecord("x")
        RecordEdits.setManualIntent(nil, on: &empty)
        XCTAssertEqual(empty.triage, TriageResult.manual(intent: nil, mentionsDatetime: false))
    }

    /// 本物の TriageQueue（分類器などはフェイク）: アプリの依頼口から、手で変えた意図が注釈の編集後も上書きされないこと。
    func testRealQueueKeepsManualIntentAfterAnnotationEdit() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let classifier = FakeClassifier()
        let embedder = SwitchableEmbedder(dimension: 4)
        await embedder.install(FakePreparableEmbedder(signature: "s1"))
        let queue = TriageQueue(store: store, classifier: classifier, scanner: FakeScanner(), embedder: embedder,
                                screenshots: FakeScreenshotLoader())
        let app: any TriageQueuing = queue

        var r = makeRecord("あとで調べる")
        try await store.insert(r)
        await app.enqueue(id: r.id)
        await app.waitUntilIdle()
        r = try await fetch(store, r.id)
        XCTAssertEqual(r.triage?.intent, .code)
        XCTAssertEqual(r.guardInfo.status, .clear)
        XCTAssertNotNil(store.embeddings.get()[r.id])
        XCTAssertEqual(classifier.calls.get(), 1)

        // ユーザーが意図を手で変え、注釈も直した → 意図は推定し直さない、索引は作り直す
        try await store.modify(id: r.id) { rec in
            RecordEdits.setManualIntent(.research, on: &rec)
            RecordEdits.setAnnotation("論文を読む", on: &rec)
        }
        store.embeddings.update { $0[r.id] = nil }
        await app.annotationEdited(id: r.id)
        await app.waitUntilIdle()
        let after = try await fetch(store, r.id)
        XCTAssertEqual(after.triage?.intent, .research)
        XCTAssertTrue(after.triage?.isManual == true)
        XCTAssertEqual(classifier.calls.get(), 1)
        XCTAssertNotNil(store.embeddings.get()[r.id])
    }

    /// 埋め込みが準備中なら索引ステップだけ失敗で残り、記録とガード・意図は進む（揃ってから resumePending で拾う）。
    func testIndexIsDeferredUntilEmbedderIsReady() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let embedder = SwitchableEmbedder(dimension: 4)
        let queue = TriageQueue(store: store, classifier: FakeClassifier(), scanner: FakeScanner(), embedder: embedder,
                                screenshots: FakeScreenshotLoader())
        let r = makeRecord("メモ")
        try await store.insert(r)
        await queue.enqueue(id: r.id)
        await queue.waitUntilIdle()
        let saved = try await fetch(store, r.id)
        XCTAssertEqual(saved.triage?.intent, .code)
        XCTAssertNil(store.embeddings.get()[r.id])

        await embedder.install(FakePreparableEmbedder(signature: "s1"))
        let n = try await queue.resumePending()
        XCTAssertEqual(n, 1)
        await queue.waitUntilIdle()
        XCTAssertNotNil(store.embeddings.get()[r.id])
    }
}

// MARK: - ガードの確認（F-10）

final class GuardReviewerTests: XCTestCase {
    private func makeReviewer(_ store: TestStore) -> LiveGuardReviewer {
        LiveGuardReviewer(store: store, modify: { id, t in try await store.modify(id: id, t) })
    }

    /// 白地に黒くない帯を描いた画像を PNG で書き、要確認の記録を作る。
    private func insertNeedsReview(_ store: TestStore, findings: [SecretFinding]) async throws -> ContextRecord {
        var r = makeRecord("トークンが古い")
        let png = try XCTUnwrap(ScreenshotEncoder.encode(TestImages.solid(width: 200, height: 100),
                                                         formats: [.init(type: .png, fileExtension: "png")]))
        r.screenshotPath = try await store.writeAttachment(png.data, id: r.id, kind: .screenshot, ext: "png", capturedAt: r.capturedAt)
        r.guardInfo = GuardInfo(status: .needsReview, findings: findings)
        try await store.insert(r)
        return r
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // (x, y) は左上原点。CGContext は左下原点なので反転して 1px だけ描く。
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (px[0], px[1], px[2])
    }

    func testUseMaskedImageWritesHEICAndMarksMasked() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let finding = SecretFinding(kind: "github_token", bbox: CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.2))
        let r = try await insertNeedsReview(store, findings: [finding])

        let updated = try await makeReviewer(store).useMaskedImage(recordID: r.id)
        XCTAssertEqual(updated.guardInfo.status, .masked)
        let masked = try XCTUnwrap(updated.maskedScreenshotPath)
        XCTAssertTrue(masked.hasSuffix("-masked.heic"), masked)
        let stored = try await store.get(id: r.id)
        XCTAssertEqual(stored, updated)
        XCTAssertEqual(updated.screenshotPath, r.screenshotPath, "元のスクショは残す")

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(store.root.appendingPathComponent(masked) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(image.width, 200)
        // 検出箇所の中心は黒く塗られ、外側（左上）は元の色のまま。
        let inside = pixel(image, x: 130, y: 60)
        XCTAssertLessThan(Int(inside.0) + Int(inside.1) + Int(inside.2), 30, "\(inside)")
        let outside = pixel(image, x: 2, y: 2)
        XCTAssertGreaterThan(Int(outside.2), 120, "\(outside)")
    }

    func testMarkReviewedClearsOnlyNeedsReview() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = try await insertNeedsReview(store, findings: [SecretFinding(kind: "password", bbox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))])
        let reviewer = makeReviewer(store)
        let cleared = try await reviewer.markReviewed(recordID: r.id)
        XCTAssertEqual(cleared.guardInfo.status, .clear)
        let clearedStatus = try await store.get(id: r.id)?.guardInfo.status
        XCTAssertEqual(clearedStatus, .clear)
        // 2 回目は何もしない
        _ = try await reviewer.markReviewed(recordID: r.id)

        var pending = makeRecord("ガード処理中")
        pending.guardInfo = GuardInfo(status: .pending)
        try await store.insert(pending)
        do {
            _ = try await reviewer.markReviewed(recordID: pending.id)
            XCTFail("pending は確認済みにしない")
        } catch let e as LiveGuardReviewer.ReviewError {
            XCTAssertEqual(e, .notNeedingReview(.pending))
        }
        let pendingStatus = try await store.get(id: pending.id)?.guardInfo.status
        XCTAssertEqual(pendingStatus, .pending)
    }

    /// マスクを作っている間にスクショが差し替わったら、書かずに失敗し、作ったマスク画像を消す。
    func testMaskIsDiscardedWhenRecordChangedMeanwhile() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = try await insertNeedsReview(store, findings: [SecretFinding(kind: "aws_key", bbox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))])
        let reviewer = LiveGuardReviewer(store: store, modify: { id, t in
            // 書く直前に別の処理がスクショを差し替えた
            try await store.modify(id: id) { $0.screenshotPath = "captures/other.png" }
            return try await store.modify(id: id, t)
        })
        let before = store.attachmentFileCount()
        do {
            _ = try await reviewer.useMaskedImage(recordID: r.id)
            XCTFail("throw するはず")
        } catch let e as LiveGuardReviewer.ReviewError {
            XCTAssertEqual(e, .changedDuringMasking)
        }
        let latest = try await fetch(store, r.id)
        XCTAssertEqual(latest.guardInfo.status, .needsReview)
        XCTAssertNil(latest.maskedScreenshotPath)
        XCTAssertEqual(store.attachmentFileCount(), before, "作ったマスク画像は消す")
    }
}

// MARK: - 検索（F-11）とフォールバック

final class EmbeddingSearchTests: XCTestCase {
    private func seededStore() async throws -> (TestStore, ContextRecord, ContextRecord) {
        let store = TestStore()
        let a = makeRecord("ビデオ会議の画面", at: 0)
        let b = makeRecord("Hermes のアダプタ", at: -10)
        for r in [a, b] { try await store.insert(r) }
        try await store.setEmbedding(id: a.id, vector: [1, 0, 0, 0])
        try await store.setEmbedding(id: b.id, vector: [0, 1, 0, 0])
        return (store, a, b)
    }

    func testFallsBackToSubstringWhilePreparing() async throws {
        let (store, _, b) = try await seededStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let embedder = SwitchableEmbedder(dimension: 4)
        let service = EmbeddingSearchService(embedder: embedder, store: store, readiness: { .preparing })
        let response = try await service.searchWithNotice("hermes", limit: 10)
        XCTAssertEqual(response.hits.map(\.record.id), [b.id])
        XCTAssertEqual(response.notice, "検索の準備中のため、文字の一致で探しています")
        XCTAssertTrue(store.searchCalls.get().isEmpty, "準備中はベクトル検索しない")

        let rebuilding = EmbeddingSearchService(embedder: embedder, store: store, readiness: { .rebuilding })
        let r2 = try await rebuilding.searchWithNotice("hermes", limit: 10)
        XCTAssertEqual(r2.notice, EmbeddingSearchService.preparingNotice)
        let unavailable = EmbeddingSearchService(embedder: embedder, store: store, readiness: { .unavailable })
        let r3 = try await unavailable.searchWithNotice("hermes", limit: 10)
        XCTAssertEqual(r3.notice, EmbeddingSearchService.unavailableNotice)
    }

    func testUsesVectorSearchWhenReady() async throws {
        let (store, a, _) = try await seededStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let embedder = SwitchableEmbedder(dimension: 4)
        await embedder.install(FakePreparableEmbedder(signature: "s"))
        let service = EmbeddingSearchService(embedder: embedder, store: store, readiness: { .ready })
        // 文字では一致しない語でも、見た目（ベクトル）で見つかる
        let response = try await service.searchWithNotice("オンラインミーティング", limit: 1)
        XCTAssertNil(response.notice)
        XCTAssertEqual(response.hits.map(\.record.id), [a.id])
        XCTAssertEqual(store.searchCalls.get(), [[1, 0, 0, 0]])
        // search（プロトコルの基本形）も同じ結果
        let plain = try await service.search("オンラインミーティング", limit: 1)
        XCTAssertEqual(plain.map(\.record.id), [a.id])
    }

    func testFallsBackWhenQueryEmbeddingFails() async throws {
        let (store, _, b) = try await seededStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let embedder = SwitchableEmbedder(dimension: 4)
        await embedder.install(FakePreparableEmbedder(signature: "s", failQuery: true))
        let service = EmbeddingSearchService(embedder: embedder, store: store, readiness: { .ready })
        let response = try await service.searchWithNotice("アダプタ", limit: 10)
        XCTAssertEqual(response.hits.map(\.record.id), [b.id])
        XCTAssertEqual(response.notice, EmbeddingSearchService.failedNotice)
    }

    func testSwitchableEmbedderThrowsUntilReady() async throws {
        let embedder = SwitchableEmbedder(dimension: 4)
        do {
            _ = try await embedder.embedQuery("x")
            XCTFail("準備前は throw")
        } catch is EmbeddingNotReady {}
        let failing = await embedder.install(FakePreparableEmbedder(signature: "s", failPrepare: true))
        guard case .failed = failing else { return XCTFail("\(failing)") }
        do {
            _ = try await embedder.embedDocument(text: "x", title: nil, image: nil)
            XCTFail("準備に失敗したら throw")
        } catch is EmbeddingNotReady {}

        let first = FakePreparableEmbedder(signature: "a")
        let installed = await embedder.install(first)
        XCTAssertEqual(installed, .ready)
        let v = try await embedder.embedQuery("x")
        XCTAssertEqual(v, [1, 0, 0, 0])
        let sigA = await embedder.indexSignature
        XCTAssertEqual(sigA, "a")
        // 差し替えたら古いほうは解放する
        await embedder.install(FakePreparableEmbedder(signature: "b"))
        let firstUnloaded = await first.unloaded
        XCTAssertTrue(firstUnloaded)
        let sigB = await embedder.indexSignature
        XCTAssertEqual(sigB, "b")
    }
}

// MARK: - 索引シグネチャと作り直し

@MainActor
final class SearchIndexMaintainerTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func make(store: TestStore, queue: FakeTriageQueue, modelPresent: Bool = true,
                      created: Box<[Int]> = Box([])) -> SearchIndexMaintainer {
        SearchIndexMaintainer(embedder: SwitchableEmbedder(dimension: 4), queue: queue, store: store,
                              stateURL: SearchIndexState.url(dataRoot: dir)) { tokens in
            created.update { $0.append(tokens) }
            return modelPresent ? FakePreparableEmbedder(signature: "sig/img\(tokens)") : nil
        }
    }

    func testFirstActivationReindexesAllAndSavesSignature() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let records = [makeRecord("a", at: 0), makeRecord("b", at: -1), makeRecord("c", at: -2)]
        for r in records { try await store.insert(r) }
        let queue = FakeTriageQueue()
        let m = make(store: store, queue: queue)
        var seen: [SearchReadiness] = []
        m.onReadinessChange = { seen.append($0) }

        await m.activate(imageTokens: 280).value
        XCTAssertEqual(Set(queue.reindexed), Set(records.map(\.id)))
        XCTAssertEqual(queue.reindexed.first, records[0].id, "新しいものから")
        XCTAssertEqual(m.readiness, .ready)
        XCTAssertEqual(seen, [.preparing, .rebuilding, .ready])
        let state = try XCTUnwrap(SearchIndexState.read(from: SearchIndexState.url(dataRoot: dir)))
        XCTAssertEqual(state.indexSignature, "sig/img280")
        XCTAssertEqual(state.imageTokens, 280)
        XCTAssertEqual(state.dimension, 4)
        XCTAssertEqual(state.status, .ready)
        XCTAssertTrue(queue.calls.get().contains(.resumePending))
    }

    func testSameSignatureDoesNotReindex() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try await store.insert(makeRecord("a"))
        try SearchIndexState(indexSignature: "sig/img280", imageTokens: 280, dimension: 4, status: .ready, updatedAt: Date())
            .write(to: SearchIndexState.url(dataRoot: dir))
        let queue = FakeTriageQueue()
        let m = make(store: store, queue: queue)
        await m.activate(imageTokens: 280).value
        XCTAssertTrue(queue.reindexed.isEmpty)
        XCTAssertEqual(m.readiness, .ready)
        XCTAssertTrue(queue.calls.get().contains(.resumePending), "埋め込みの無い記録は resumePending が拾う")
    }

    func testImageTokenChangeReindexesAll() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let records = [makeRecord("a", at: 0), makeRecord("b", at: -1)]
        for r in records { try await store.insert(r) }
        try SearchIndexState(indexSignature: "sig/img280", imageTokens: 280, dimension: 4, status: .ready, updatedAt: Date())
            .write(to: SearchIndexState.url(dataRoot: dir))
        let queue = FakeTriageQueue()
        let created = Box<[Int]>([])
        let m = make(store: store, queue: queue, created: created)
        await m.activate(imageTokens: 280).value
        XCTAssertTrue(queue.reindexed.isEmpty)

        // 同じ値の設定変更では作り直さない
        m.settingsChanged(imageTokens: 280)
        await m.waitForActivation()
        XCTAssertEqual(created.get(), [280])

        m.settingsChanged(imageTokens: 70)
        await m.waitForActivation()
        XCTAssertEqual(created.get(), [280, 70])
        XCTAssertEqual(Set(queue.reindexed), Set(records.map(\.id)))
        XCTAssertEqual(SearchIndexState.read(from: SearchIndexState.url(dataRoot: dir))?.indexSignature, "sig/img70")
        XCTAssertEqual(m.readiness, .ready)
    }

    /// 前回の作り直しが途中（status: rebuilding）なら、シグネチャが同じでも作り直す。
    func testUnfinishedRebuildIsRedone() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let r = makeRecord("a")
        try await store.insert(r)
        try SearchIndexState(indexSignature: "sig/img280", imageTokens: 280, dimension: 4, status: .rebuilding, updatedAt: Date())
            .write(to: SearchIndexState.url(dataRoot: dir))
        let queue = FakeTriageQueue()
        let m = make(store: store, queue: queue)
        await m.activate(imageTokens: 280).value
        XCTAssertEqual(queue.reindexed, [r.id])
        XCTAssertEqual(SearchIndexState.read(from: SearchIndexState.url(dataRoot: dir))?.status, .ready)
    }

    func testMissingModelKeepsSubstringSearchAndResumesOtherSteps() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try await store.insert(makeRecord("a"))
        let queue = FakeTriageQueue()
        let m = make(store: store, queue: queue, modelPresent: false)
        await m.activate(imageTokens: 280).value
        XCTAssertEqual(m.readiness, .unavailable)
        XCTAssertTrue(queue.reindexed.isEmpty)
        XCTAssertEqual(queue.calls.get(), [.resumePending])
        XCTAssertNil(SearchIndexState.read(from: SearchIndexState.url(dataRoot: dir)))
    }
}

// MARK: - モデルの準備（順序・ディスク）

final class ModelPreparationPipelineTests: XCTestCase {
    final class FakeSlot: ModelSlotPreparing, @unchecked Sendable {
        let displayName: String
        let downloadBytes: Int64
        let requiredFreeBytes: Int64
        let present: Box<Bool>
        let log: Box<[String]>

        init(_ name: String, bytes: Int64, required: Int64, present: Bool, log: Box<[String]>) {
            displayName = name
            downloadBytes = bytes
            requiredFreeBytes = required
            self.present = Box(present)
            self.log = log
        }

        func filesPresent() -> Bool { present.get() }
        func isPrepared() async -> Bool { present.get() }
        func prepare(progress: @escaping @Sendable (ModelPreparationProgress.Phase, Double) -> Void) async throws {
            log.update { $0.append(displayName) }
            progress(.downloading, 0.5)
            progress(.optimizing, 1)
            present.set(true)
        }
    }

    private func slots(_ log: Box<[String]>, whisperPresent: Bool = false) -> [FakeSlot] {
        [
            FakeSlot("文字起こしモデル", bytes: 1_600, required: 1_900, present: whisperPresent, log: log),
            FakeSlot("検索モデル", bytes: 850, required: 2_000, present: false, log: log),
            FakeSlot("意図の推定モデル", bytes: 5_800, required: 9_200, present: false, log: log),
        ]
    }

    func testPreparesInOrderAndReportsProgress() async throws {
        let log = Box<[String]>([])
        let prepared = Box(false)
        let s = slots(log)
        let pipeline = ModelPreparationPipeline(slots: s, availableBytes: { 100_000 }, onPrepared: { prepared.set(true) })
        let preparedBefore = await pipeline.isPrepared()
        XCTAssertFalse(preparedBefore)
        XCTAssertEqual(pipeline.requiredFreeBytes(), 13_100)

        var progress: [ModelPreparationProgress] = []
        for try await p in pipeline.prepare() { progress.append(p) }
        XCTAssertEqual(log.get(), ["文字起こしモデル", "検索モデル", "意図の推定モデル"])
        XCTAssertTrue(prepared.get())
        XCTAssertEqual(progress.last?.phase, .finished)
        XCTAssertEqual(progress.last?.fractionCompleted, 1)
        let fractions = progress.map(\.fractionCompleted)
        XCTAssertEqual(fractions, fractions.sorted(), "進捗は戻らない")
        XCTAssertEqual(progress.last?.totalBytes, 8_250)
        XCTAssertTrue(progress.contains { $0.currentItem == "意図の推定モデル" })
        let preparedAfter = await pipeline.isPrepared()
        XCTAssertTrue(preparedAfter)
    }

    func testStopsBeforeDownloadingWhenDiskIsShort() async throws {
        let log = Box<[String]>([])
        let prepared = Box(false)
        // 文字起こしは揃っている → 検索 2,000 + 意図 9,200 = 11,200 が要る
        let pipeline = ModelPreparationPipeline(slots: slots(log, whisperPresent: true), availableBytes: { 5_000 },
                                                onPrepared: { prepared.set(true) })
        do {
            for try await _ in pipeline.prepare() {}
            XCTFail("空き容量不足で throw するはず")
        } catch let e as InsufficientDiskSpace {
            XCTAssertEqual(e, InsufficientDiskSpace(requiredBytes: 11_200, availableBytes: 5_000))
            XCTAssertTrue(e.errorDescription?.contains("空き容量が足りません") == true)
        }
        XCTAssertTrue(log.get().isEmpty, "何も取りに行かない")
        XCTAssertFalse(prepared.get())
    }

    func testSkipsDiskCheckWhenEverythingIsPresent() async throws {
        let log = Box<[String]>([])
        let s = slots(log)
        for slot in s { slot.present.set(true) }
        let pipeline = ModelPreparationPipeline(slots: s, availableBytes: { 0 })
        var last: ModelPreparationProgress?
        for try await p in pipeline.prepare() { last = p }
        XCTAssertEqual(last?.phase, .finished)
        // 揃っていても prepare は呼ぶ（文字起こしはこのプロセスでの読み込みがある。他は揃っていれば何もしない実装）
        XCTAssertEqual(log.get().count, 3)
    }
}
