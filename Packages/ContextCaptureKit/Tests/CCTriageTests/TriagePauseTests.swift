import CCCore
import CCStore
import XCTest
@testable import CCTriage

/// `TriageQueue.pause()` / `resume()`（キャプチャ中は次のステップを始めない。docs/e2e/report.md §7）。
final class TriagePauseTests: XCTestCase {
    var temp: TempStore!
    var classifier: FakeClassifier!
    var scanner: FakeScanner!
    var embedder: FakeEmbedder!

    override func setUp() async throws {
        temp = try TempStore()
        classifier = FakeClassifier()
        scanner = FakeScanner()
        embedder = FakeEmbedder()
    }

    private func makeQueue(maxPause: Duration = .seconds(180)) -> TriageQueue {
        TriageQueue(store: temp.store, classifier: classifier, scanner: scanner, embedder: embedder, screenshots: FakeLoader(),
                    configuration: .init(maxPauseDuration: maxPause))
    }

    private func stepEvents(_ events: [TriageEvent]) -> [TriageEvent] {
        events.filter { if case .stepFinished = $0 { return true } else { return false } }
    }

    func testPausedQueueDoesNotStartStepsUntilResumed() async throws {
        let r = makeRecord()
        try await temp.store.insert(r)
        let q = makeQueue()
        let events = EventCollector(await q.events())
        await q.pause()
        await q.enqueue(id: r.id)
        let suspended = await events.wait { $0.contains(.suspendedForCapture) }
        XCTAssertTrue(suspended, "worker reached the pause boundary")
        XCTAssertEqual(scanner.calls, 0, "止まっている間はガードを始めない")
        let texts = await classifier.texts
        XCTAssertEqual(texts, [])
        XCTAssertEqual(embedder.calls.count, 0)
        XCTAssertEqual(stepEvents(events.events), [])
        let busy = await q.isBusy
        XCTAssertTrue(busy, "投入は受け付けている")

        await q.resume()
        await q.waitUntilIdle()
        XCTAssertEqual(scanner.calls, 1)
        XCTAssertEqual(embedder.calls.count, 1)
        let saved = try await temp.store.get(id: r.id)
        XCTAssertEqual(saved?.triage?.intent, .todo)
        let paused = await q.isPaused
        XCTAssertFalse(paused)
    }

    func testPauseDuringStepLetsItFinishButNotTheNextStep() async throws {
        let r = makeRecord(screenshot: nil)
        try await temp.store.insert(r)
        await classifier.holdNextCall()
        let q = makeQueue()
        let events = EventCollector(await q.events())
        await q.enqueue(id: r.id)
        await classifier.waitUntilHeld()
        // 意図ステップの途中でキャプチャが始まった。
        await q.pause()
        await classifier.release()
        let intentDone = await events.wait { $0.contains(.stepFinished(id: r.id, step: .intent, outcome: .succeeded)) }
        XCTAssertTrue(intentDone, "進行中のステップは中断しない")
        let suspended = await events.wait { $0.contains(.suspendedForCapture) }
        XCTAssertTrue(suspended, "worker reached the pause boundary")
        XCTAssertEqual(embedder.calls.count, 0, "次のステップ（索引）は始めない")
        XCTAssertFalse(events.events.contains(.recordFinished(id: r.id)))

        await q.resume()
        await q.waitUntilIdle()
        XCTAssertEqual(embedder.calls.count, 1)
        XCTAssertTrue(events.events.contains(.stepFinished(id: r.id, step: .index, outcome: .succeeded)))
    }

    func testPauseBetweenRecordsHoldsTheNextRecord() async throws {
        let a = makeRecord(offset: 0, screenshot: nil)
        let b = makeRecord(offset: 1, text: "あとで読む", screenshot: nil)
        try await temp.store.insert(a)
        try await temp.store.insert(b)
        await classifier.holdNextCall()
        let q = makeQueue()
        let events = EventCollector(await q.events())
        await q.enqueue(id: a.id)
        await q.enqueue(id: b.id)
        await classifier.waitUntilHeld()
        await q.pause()
        await classifier.release()
        let suspended = await events.wait { $0.contains(.suspendedForCapture) }
        XCTAssertTrue(suspended, "worker reached the pause boundary")
        let texts = await classifier.texts
        XCTAssertEqual(texts.count, 1, "2 件目の意図推定は始めない")
        XCTAssertFalse(events.events.contains { if case .stepFinished(b.id, _, _) = $0 { return true } else { return false } })

        await q.resume()
        await q.waitUntilIdle()
        let after = await classifier.texts
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(embedder.calls.count, 2)
    }

    func testPauseAndResumeAreIdempotent() async throws {
        let r = makeRecord(screenshot: nil)
        try await temp.store.insert(r)
        let q = makeQueue()
        await q.resume() // 止まっていなければ何もしない
        await q.pause()
        await q.pause()
        await q.enqueue(id: r.id)
        await q.resume()
        await q.waitUntilIdle()
        XCTAssertEqual(embedder.calls.count, 1)
        let auto = await q.autoResumeCount
        XCTAssertEqual(auto, 0)
    }

    func testForgottenResumeIsRecoveredByMaxPauseDuration() async throws {
        let r = makeRecord(screenshot: nil)
        try await temp.store.insert(r)
        let q = makeQueue(maxPause: .milliseconds(150))
        await q.pause()
        await q.enqueue(id: r.id)
        // resume() を呼ばない（呼び出し側の取りこぼし）。
        await q.waitUntilIdle()
        XCTAssertEqual(embedder.calls.count, 1)
        let auto = await q.autoResumeCount
        XCTAssertEqual(auto, 1)
        let paused = await q.isPaused
        XCTAssertFalse(paused)
    }

    func testResumeCancelsTheAutoResumeTimer() async throws {
        let q = makeQueue(maxPause: .milliseconds(100))
        await q.pause()
        await q.resume()
        await q.pause()
        try await Task.sleep(for: .milliseconds(60))
        await q.resume()
        try await Task.sleep(for: .milliseconds(150))
        let auto = await q.autoResumeCount
        XCTAssertEqual(auto, 0, "前の pause のタイマが後から自動再開を数えない")
    }
}
