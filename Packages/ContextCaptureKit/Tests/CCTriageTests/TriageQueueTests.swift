import CCCore
import CCStore
import CoreGraphics
import XCTest
@testable import CCTriage

final class TriageQueueTests: XCTestCase {
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

    private func makeQueue(idle: Duration = .seconds(600), maxChars: Int = AnnotationPreprocessor.maxCharacters) -> TriageQueue {
        TriageQueue(store: temp.store, classifier: classifier, scanner: scanner, embedder: embedder, screenshots: loader,
                    configuration: .init(classifierIdleTimeout: idle, maxAnnotationCharacters: maxChars))
    }

    private func fetch(_ id: String) async throws -> ContextRecord {
        let r = try await temp.store.get(id: id)
        return try XCTUnwrap(r)
    }

    private func embeddedIDs() async throws -> Set<String> {
        try await temp.store.idsWithEmbedding(dimension: 256)
    }

    // MARK: - 正常系

    func testHappyPathRunsAllStepsAndWritesFields() async throws {
        let r = makeRecord()
        try await temp.store.insert(r)
        scanner.findings = [SecretFinding(kind: "openai_key", bbox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.02))]
        let q = makeQueue()
        let events = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()

        let saved = try await fetch(r.id)
        XCTAssertEqual(saved.guardInfo.status, .needsReview)
        XCTAssertEqual(saved.guardInfo.findings.map(\.kind), ["openai_key"])
        XCTAssertEqual(saved.triage?.intent, .todo)
        XCTAssertEqual(saved.triage?.model, "fake-d1")
        let embedded = try await embeddedIDs()
        XCTAssertTrue(embedded.contains(r.id), "needs_review でも検索インデックスには入れる")
        XCTAssertEqual(embedder.calls, [.init(text: r.annotation.text, title: "Slack", hasImage: true)])

        let ok = await events.wait { $0.contains(.idle) }
        XCTAssertTrue(ok)
        XCTAssertEqual(events.events, [
            .stepFinished(id: r.id, step: .guardScan, outcome: .succeeded),
            .stepFinished(id: r.id, step: .intent, outcome: .succeeded),
            .stepFinished(id: r.id, step: .index, outcome: .succeeded),
            .recordFinished(id: r.id),
            .idle,
        ])
    }

    func testNoScreenshotIsClearWithoutScanning() async throws {
        let r = makeRecord(screenshot: nil)
        try await temp.store.insert(r)
        let q = makeQueue()
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let saved = try await temp.store.get(id: r.id)
        XCTAssertEqual(saved?.guardInfo.status, .clear)
        XCTAssertEqual(scanner.calls, 0)
        XCTAssertEqual(embedder.calls.first?.hasImage, false)
    }

    func testRecordsAreProcessedSeriallyInOrder() async throws {
        let ids = (0..<3).map { _ in ULID.generate().string }
        for (i, id) in ids.enumerated() { try await temp.store.insert(makeRecord(id: id, offset: Double(i), text: "メモ\(i)")) }
        let q = makeQueue()
        for id in ids { await q.enqueue(id: id) }
        await q.waitUntilIdle()
        let texts = await classifier.texts
        XCTAssertEqual(texts, ["メモ0", "メモ1", "メモ2"])
    }

    // MARK: - 失敗の独立性

    func testGuardFailureLeavesPendingAndOtherStepsRun() async throws {
        let r = makeRecord()
        try await temp.store.insert(r)
        scanner.fail = true
        let q = makeQueue()
        let events = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let saved = try await fetch(r.id)
        XCTAssertEqual(saved.guardInfo.status, .pending)
        XCTAssertNotNil(saved.triage)
        let embedded = try await embeddedIDs()
        XCTAssertTrue(embedded.contains(r.id))
        _ = await events.wait { $0.contains(.idle) }
        XCTAssertTrue(events.events.contains {
            if case .stepFinished(_, .guardScan, .failed) = $0 { return true } else { return false }
        })
    }

    func testIntentFailureDoesNotStopIndexOrGuard() async throws {
        let r = makeRecord()
        try await temp.store.insert(r)
        await classifier.setFail(true)
        let q = makeQueue()
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let saved = try await fetch(r.id)
        XCTAssertNil(saved.triage)
        XCTAssertEqual(saved.guardInfo.status, .clear)
        let embedded = try await embeddedIDs()
        XCTAssertTrue(embedded.contains(r.id))
    }

    func testIndexFailureDoesNotStopOthers() async throws {
        let r = makeRecord()
        try await temp.store.insert(r)
        embedder.fail = true
        let q = makeQueue()
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let saved = try await fetch(r.id)
        XCTAssertNotNil(saved.triage)
        XCTAssertEqual(saved.guardInfo.status, .clear)
        let embedded = try await embeddedIDs()
        XCTAssertFalse(embedded.contains(r.id))
    }

    func testScreenshotLoadFailureKeepsGuardPendingButIndexesTextOnly() async throws {
        let r = makeRecord()
        try await temp.store.insert(r)
        loader.fail = true
        let q = makeQueue()
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let saved = try await fetch(r.id)
        XCTAssertEqual(saved.guardInfo.status, .pending)
        XCTAssertEqual(embedder.calls.first?.hasImage, false)
    }

    func testDeletedRecordIsSkipped() async throws {
        let q = makeQueue()
        let events = EventCollector(await q.events())
        await q.enqueue(id: "missing")
        await q.waitUntilIdle()
        _ = await events.wait { $0.contains(.idle) }
        XCTAssertTrue(events.events.contains(.stepFinished(id: "missing", step: .intent, outcome: .skipped(.recordMissing))))
    }

    // MARK: - 手動変更を上書きしない

    func testManualIntentIsNotOverwritten() async throws {
        var r = makeRecord()
        r.triage = .manual(intent: .research, mentionsDatetime: false)
        try await temp.store.insert(r)
        let q = makeQueue()
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let saved = try await temp.store.get(id: r.id)
        XCTAssertEqual(saved?.triage?.intent, .research)
        XCTAssertEqual(saved?.triage?.model, TriageMarkers.manualModel)
        let texts = await classifier.texts
        XCTAssertEqual(texts, [], "手動変更済みなら分類器も呼ばない")
    }

    func testManualChangeDuringClassificationWins() async throws {
        let r = makeRecord(screenshot: nil)
        try await temp.store.insert(r)
        await classifier.holdNextCall()
        let q = makeQueue()
        let events = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await classifier.waitUntilHeld()
        // 推定中にユーザーが意図を手で変える。
        try await temp.store.modify(id: r.id) { $0.triage = .manual(intent: .note, mentionsDatetime: false) }
        await classifier.release()
        await q.waitUntilIdle()
        let saved = try await temp.store.get(id: r.id)
        XCTAssertEqual(saved?.triage?.intent, .note)
        XCTAssertTrue(saved?.triage?.isManual ?? false)
        _ = await events.wait { $0.contains(.idle) }
        XCTAssertTrue(events.events.contains(.stepFinished(id: r.id, step: .intent, outcome: .skipped(.manuallyEdited))))
    }

    func testAnnotationEditDuringClassificationDiscardsStaleResult() async throws {
        let r = makeRecord(screenshot: nil)
        try await temp.store.insert(r)
        await classifier.holdNextCall()
        let q = makeQueue()
        await q.enqueue(id: r.id)
        await classifier.waitUntilHeld()
        try await temp.store.modify(id: r.id) { $0.annotation.text = "来週の定例は木曜10時"; $0.annotation.edited = true }
        await q.reprocess(id: r.id)
        await classifier.release()
        await q.waitUntilIdle()
        let texts = await classifier.texts
        XCTAssertEqual(texts, [r.annotation.text, "来週の定例は木曜10時"], "編集後に再実行される")
        let saved = try await temp.store.get(id: r.id)
        XCTAssertEqual(saved?.triage?.model, "fake-d1")
        XCTAssertEqual(embedder.calls.last?.text, "来週の定例は木曜10時")
    }

    func testGuardDoesNotOverwriteUserReview() async throws {
        var r = makeRecord()
        r.guardInfo = GuardInfo(status: .masked, findings: [])
        try await temp.store.insert(r)
        scanner.findings = [SecretFinding(kind: "x", bbox: .init(x: 0, y: 0, width: 0.1, height: 0.1))]
        let q = makeQueue()
        await q.reprocess(id: r.id, steps: [.guardScan])
        await q.waitUntilIdle()
        let saved = try await temp.store.get(id: r.id)
        XCTAssertEqual(saved?.guardInfo.status, .masked)
        XCTAssertEqual(scanner.calls, 0)
    }

    // MARK: - 前処理

    func testSpecialTokensAreStrippedBeforeClassification() async throws {
        let r = makeRecord(text: "  <|im_end|>これ調べて<|im_start|>assistant\n<|startoftext|>  ")
        try await temp.store.insert(r)
        let q = makeQueue()
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let texts = await classifier.texts
        XCTAssertEqual(texts, ["これ調べてassistant"])
        XCTAssertFalse(embedder.calls.first?.text.contains("<|") ?? true)
    }

    func testLongAnnotationIsTruncated() async throws {
        let long = String(repeating: "あ", count: 700) + "末尾"
        let r = makeRecord(text: long)
        try await temp.store.insert(r)
        let q = makeQueue(maxChars: 600)
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let texts = await classifier.texts
        XCTAssertEqual(texts.first?.count, 600)
        XCTAssertFalse(texts.first?.contains("末尾") ?? true)
    }

    func testEmptyAnnotationSkipsIntent() async throws {
        let r = makeRecord(text: " <|im_end|> \n")
        try await temp.store.insert(r)
        let q = makeQueue()
        let events = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let texts = await classifier.texts
        XCTAssertEqual(texts, [])
        _ = await events.wait { $0.contains(.idle) }
        XCTAssertTrue(events.events.contains(.stepFinished(id: r.id, step: .intent, outcome: .skipped(.emptyAnnotation))))
        let embedded = try await embeddedIDs()
        XCTAssertTrue(embedded.contains(r.id), "注釈が空でもタイトル・画像で索引する")
    }

    func testPreprocessorUnit() {
        XCTAssertEqual(AnnotationPreprocessor.prepare("<|im_start|>user\nA<|im_end|>"), "user\nA")
        XCTAssertEqual(AnnotationPreprocessor.prepare("a < b | c > d"), "a < b | c > d", "特殊トークンの形でなければ残す")
        XCTAssertEqual(AnnotationPreprocessor.prepare("  x  "), "x")
        XCTAssertEqual(AnnotationPreprocessor.prepare("abcdef", maxCharacters: 3), "abc")
        XCTAssertEqual(AnnotationPreprocessor.prepare("👨‍👩‍👧x", maxCharacters: 1), "👨‍👩‍👧", "書記素単位で切る")
    }

    // MARK: - 再開

    func testResumePendingEnqueuesOnlyIncompleteStepsOldestFirst() async throws {
        // a: 全部未完了（古い）、b: 全部完了、c: 埋め込みだけ無い（新しい）
        let a = makeRecord(offset: 0, text: "古い")
        var b = makeRecord(offset: 10, text: "完了")
        b.guardInfo = GuardInfo(status: .clear)
        b.triage = TriageResult(intent: .note, intentConfidence: 0.9, mentionsDatetime: false, model: "fake-d1")
        var c = makeRecord(offset: 20, text: "新しい")
        c.guardInfo = GuardInfo(status: .clear)
        c.triage = TriageResult(intent: .note, intentConfidence: 0.9, mentionsDatetime: false, model: "fake-d1")
        for r in [c, b, a] { try await temp.store.insert(r) }
        var vec = [Float](repeating: 0, count: 256); vec[1] = 1
        try await temp.store.setEmbedding(id: b.id, vector: vec)

        let q = makeQueue()
        let n = try await q.resumePending()
        XCTAssertEqual(n, 2)
        await q.waitUntilIdle()
        let texts = await classifier.texts
        XCTAssertEqual(texts, ["古い"], "c は triage があるので intent を走らせない")
        XCTAssertEqual(embedder.calls.map(\.text), ["古い", "新しい"], "古い順")
        XCTAssertEqual(scanner.calls, 1)
        let embedded = try await embeddedIDs()
        XCTAssertEqual(embedded, [a.id, b.id, c.id])
        // 2 回目は何も積まない。
        let again = try await q.resumePending()
        XCTAssertEqual(again, 0)
    }

    func testDuplicateEnqueueIsMerged() async throws {
        let first = makeRecord(offset: 0, screenshot: nil)
        let second = makeRecord(offset: 1, screenshot: nil)
        try await temp.store.insert(first)
        try await temp.store.insert(second)
        await classifier.holdNextCall()
        let q = makeQueue()
        await q.enqueue(id: first.id)
        await classifier.waitUntilHeld()
        await q.enqueue(id: second.id)
        await q.reprocess(id: second.id)
        let pending = await q.pendingCount
        XCTAssertEqual(pending, 1)
        await classifier.release()
        await q.waitUntilIdle()
        XCTAssertEqual(embedder.calls.count, 2)
    }

    // MARK: - d1 の解放

    func testClassifierIsUnloadedAfterIdleTimeout() async throws {
        let r = makeRecord(screenshot: nil)
        try await temp.store.insert(r)
        let q = makeQueue(idle: .milliseconds(200))
        let events = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let loadedAfterRun = await classifier.isLoaded
        XCTAssertTrue(loadedAfterRun, "直後は解放しない")
        let unloaded = await events.wait(timeout: 3) { $0.contains(.classifierUnloaded) }
        XCTAssertTrue(unloaded)
        let count = await classifier.unloadCount
        XCTAssertEqual(count, 1)
    }

    func testNoUnloadWhileProcessingAndTimerRestartsOnUse() async throws {
        let a = makeRecord(offset: 0, screenshot: nil), b = makeRecord(offset: 1, screenshot: nil)
        try await temp.store.insert(a)
        try await temp.store.insert(b)
        let q = makeQueue(idle: .milliseconds(150))
        await q.enqueue(id: a.id)
        await q.waitUntilIdle()
        // タイマが切れる前に次の処理を始め、処理中（分類器で止めている間）にタイムアウトを過ぎさせる。
        await classifier.holdNextCall()
        await q.enqueue(id: b.id)
        await classifier.waitUntilHeld()
        try await Task.sleep(for: .milliseconds(400))
        let duringCount = await classifier.unloadCount
        XCTAssertEqual(duringCount, 0, "処理中は解放しない")
        await classifier.release()
        await q.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(600))
        let afterCount = await classifier.unloadCount
        XCTAssertEqual(afterCount, 1)
    }

    func testNoUnloadWhenClassifierWasNotUsed() async throws {
        let r = makeRecord(text: "", screenshot: nil)
        try await temp.store.insert(r)
        let q = makeQueue(idle: .milliseconds(50))
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))
        let count = await classifier.unloadCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - イベント

    func testMultipleSubscribersReceiveEvents() async throws {
        let r = makeRecord(screenshot: nil)
        try await temp.store.insert(r)
        let q = makeQueue()
        let e1 = EventCollector(await q.events()), e2 = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let ok1 = await e1.wait { $0.contains(.idle) }
        let ok2 = await e2.wait { $0.contains(.idle) }
        XCTAssertTrue(ok1 && ok2)
        XCTAssertEqual(e1.events, e2.events)
    }
}

// MARK: - 処理中の差し替え（遅いスキャナ・埋め込みの途中で記録が変わる）

/// スキャンの途中で `onScan` を呼ぶ（その間に記録を書き換えて「スキャン中の差し替え」を作る）。
final class HookedScanner: SecretScanning, @unchecked Sendable {
    let onScan: @Sendable () async throws -> Void
    var findings: [SecretFinding] = []
    init(findings: [SecretFinding] = [], onScan: @escaping @Sendable () async throws -> Void) {
        self.findings = findings
        self.onScan = onScan
    }
    func scan(image: CGImage) async throws -> [SecretFinding] {
        try await Task.sleep(for: .milliseconds(30))  // 遅いスキャナ
        try await onScan()
        return findings
    }
}

/// 埋め込みの途中で `onEmbed` を呼ぶ。
final class HookedEmbedder: Embedder, @unchecked Sendable {
    let dimension = 256
    let onEmbed: @Sendable () async throws -> Void
    init(onEmbed: @escaping @Sendable () async throws -> Void) { self.onEmbed = onEmbed }
    func embedQuery(_ text: String) async throws -> [Float] { unit() }
    func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] {
        try await Task.sleep(for: .milliseconds(30))
        try await onEmbed()
        return unit()
    }
    private func unit() -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        v[0] = 1
        return v
    }
}

final class TriageInFlightChangeTests: XCTestCase {
    var temp: TempStore!

    override func setUp() async throws {
        temp = try TempStore()
    }

    private func outcome(_ events: EventCollector, _ id: String, _ step: TriageStep) async -> TriageStepOutcome? {
        _ = await events.wait { $0.contains(.recordFinished(id: id)) }
        for case let .stepFinished(eid, s, o) in events.events where eid == id && s == step { return o }
        return nil
    }

    /// スキャン中にスクショが差し替わったら、古い画像の判定（clear）は書かず pending のまま次回に回す。
    func testGuardSkipsWhenScreenshotReplacedDuringScan() async throws {
        let r = makeRecord(screenshot: "captures/x/old.heic")
        try await temp.store.insert(r)
        let store = temp.store
        let scanner = HookedScanner {
            try await store.modify(id: r.id) { $0.screenshotPath = "captures/x/new.heic" }
        }
        let q = TriageQueue(store: store, classifier: FakeClassifier(), scanner: scanner, embedder: FakeEmbedder(),
                            screenshots: FakeLoader())
        let events = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let guardOutcome = await outcome(events, r.id, .guardScan)
        XCTAssertEqual(guardOutcome, .skipped(.screenshotChanged))
        let saved = try await store.get(id: r.id)
        XCTAssertEqual(saved?.guardInfo.status, .pending, "古い画像の clear を書かない")
        XCTAssertEqual(saved?.screenshotPath, "captures/x/new.heic")
        // 次回の再開で新しい画像をスキャンし直す
        let resumed = try await q.resumePending()
        XCTAssertEqual(resumed, 1)
    }

    /// スキャン中に保持期間でスクショが消えたら、古い判定（needs_review と検出箇所）を書かない（消した側の「画像なし」が残る）。
    func testGuardSkipsWhenScreenshotPurgedDuringScan() async throws {
        let r = makeRecord(offset: -100 * 86400, screenshot: nil)
        var withShot = r
        withShot.screenshotPath = try await temp.store.writeAttachment(Data([1]), id: r.id, kind: .screenshot, ext: "heic", capturedAt: r.capturedAt)
        try await temp.store.insert(withShot)
        let store = temp.store
        let finding = SecretFinding(kind: "openai_key", bbox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
        let scanner = HookedScanner(findings: [finding]) {
            _ = try await store.purgeExpiredScreenshots(retentionDays: 30)
        }
        let q = TriageQueue(store: store, classifier: FakeClassifier(), scanner: scanner, embedder: FakeEmbedder(),
                            screenshots: FakeLoader())
        let events = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let guardOutcome = await outcome(events, r.id, .guardScan)
        XCTAssertNotEqual(guardOutcome, .succeeded)
        let saved = try await store.get(id: r.id)
        XCTAssertNil(saved?.screenshotPath)
        XCTAssertEqual(saved?.guardInfo, GuardInfo(status: .clear, findings: []), "消えた画像の判定を書かない")
    }

    /// スキャン中にパスだけが消えた（guard は pending のまま）ときも `.screenshotChanged` で書かない。
    func testGuardSkipsWhenScreenshotPathRemovedDuringScan() async throws {
        let r = makeRecord(screenshot: "captures/x/s.heic")
        try await temp.store.insert(r)
        let store = temp.store
        let scanner = HookedScanner {
            try await store.modify(id: r.id) { $0.screenshotPath = nil }
        }
        let q = TriageQueue(store: store, classifier: FakeClassifier(), scanner: scanner, embedder: FakeEmbedder(),
                            screenshots: FakeLoader())
        let events = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await q.waitUntilIdle()
        let guardOutcome = await outcome(events, r.id, .guardScan)
        XCTAssertEqual(guardOutcome, .skipped(.screenshotChanged))
        let saved = try await store.get(id: r.id)
        XCTAssertEqual(saved?.guardInfo.status, .pending)
    }

    /// 埋め込み中に注釈が編集されたら、古い注釈のベクトルは書かない（`.annotationChanged`）。
    func testIndexSkipsWhenAnnotationEditedDuringEmbedding() async throws {
        let r = makeRecord(text: "古い注釈")
        try await temp.store.insert(r)
        let store = temp.store
        let embedder = HookedEmbedder {
            try await store.modify(id: r.id) { $0.annotation.text = "新しい注釈" }
        }
        let q = TriageQueue(store: store, classifier: FakeClassifier(), scanner: FakeScanner(), embedder: embedder,
                            screenshots: FakeLoader())
        let events = EventCollector(await q.events())
        await q.reprocess(id: r.id, steps: [.index])
        await q.waitUntilIdle()
        let indexOutcome = await outcome(events, r.id, .index)
        XCTAssertEqual(indexOutcome, .skipped(.annotationChanged))
        let embedded = try await store.idsWithEmbedding(dimension: 256)
        XCTAssertFalse(embedded.contains(r.id), "古い注釈のベクトルを書かない")
    }

    /// 埋め込み中にウインドウタイトルが変わったときも書かない。
    func testIndexSkipsWhenTitleChangedDuringEmbedding() async throws {
        let r = makeRecord(title: "古いタイトル")
        try await temp.store.insert(r)
        let store = temp.store
        let embedder = HookedEmbedder {
            try await store.modify(id: r.id) { $0.window = WindowInfo(title: "新しいタイトル", frame: nil) }
        }
        let q = TriageQueue(store: store, classifier: FakeClassifier(), scanner: FakeScanner(), embedder: embedder,
                            screenshots: FakeLoader())
        let events = EventCollector(await q.events())
        await q.reprocess(id: r.id, steps: [.index])
        await q.waitUntilIdle()
        let indexOutcome = await outcome(events, r.id, .index)
        XCTAssertEqual(indexOutcome, .skipped(.annotationChanged))
        let embedded = try await store.idsWithEmbedding(dimension: 256)
        XCTAssertFalse(embedded.contains(r.id))
    }
}
