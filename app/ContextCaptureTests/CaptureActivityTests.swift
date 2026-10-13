import CCCapture
import CCCore
import CCSTT
import CCTriage
import CoreGraphics
import XCTest

/// キャプチャ中（押下〜保存完了）のトリアージの一時停止（docs/e2e/report.md §7）。
/// AppCoordinator が `onCaptureActivityChanged` を 0↔1 の切り替わりで必ず対にして呼ぶこと、
/// TriageWiring がそれを順番どおりにキューへ渡すこと、本物の TriageQueue がキャプチャ中にステップを始めないこと。
@MainActor
final class CaptureActivityTests: XCTestCase {
    private var capturer: FakeCapturer!
    private var recorder: FakeRecorder!
    private var stt: FakeTranscriber!
    private var store: TestStore!
    private var clock: Box<TimeInterval>!
    private var coordinator: AppCoordinator!
    /// `onCaptureActivityChanged` に届いた値（順に）。
    private var activity: [Bool] = []

    override func setUp() async throws {
        capturer = FakeCapturer.standard()
        recorder = FakeRecorder()
        stt = FakeTranscriber()
        store = TestStore()
        clock = Box(1000)
        let clock = clock!
        coordinator = AppCoordinator(dependencies: CaptureDependencies(
            capturer: capturer, recorder: recorder, transcriber: stt, store: store,
            uptime: { clock.get() }
        ))
        activity = []
        coordinator.onCaptureActivityChanged = { [unowned self] in activity.append($0) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: store.root)
    }

    private func press(at t: TimeInterval) {
        coordinator.handle(HotKeyEvent(kind: .pressed, uptime: t, date: Date()))
    }

    private func release(at t: TimeInterval, held: TimeInterval) {
        clock.set(t)
        coordinator.handle(HotKeyEvent(kind: .released, uptime: t, date: Date(), pressDuration: held))
    }

    private func waitForPhase(_ p: AppCoordinator.Phase) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while coordinator.phase != p, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(coordinator.phase, p)
    }

    private func assertSettledAndResumed(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(activity, [true, false], "キャプチャ中を 1 回だけ知らせ、必ず戻す", file: file, line: line)
        XCTAssertEqual(coordinator.activeCaptures, 0, file: file, line: line)
    }

    // MARK: - AppCoordinator: どの終わり方でも戻す

    func testSavedCaptureIsActiveFromPressUntilSaved() async {
        let gate = Box(false)
        stt.handler.set { _, _ in
            while !gate.get() { try await Task.sleep(for: .milliseconds(5)) }
            return Transcript(text: "メモ", engine: "e")
        }
        press(at: 1000)
        XCTAssertEqual(activity, [true], "押下の時点で（録音開始を待たずに）キャプチャ中")
        await coordinator.waitUntilSettled()
        release(at: 1001.5, held: 1.5)
        await waitForPhase(.idle)
        // 録音は終わったが、文字起こし・保存の間はまだキャプチャ中。
        XCTAssertEqual(activity, [true])
        gate.set(true)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(store.records.get().count, 1)
        assertSettledAndResumed()
    }

    func testDiscardedShortPressEndsActivity() async {
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1000.2, held: 0.2)
        await coordinator.waitUntilSettled()
        XCTAssertTrue(store.records.get().isEmpty)
        assertSettledAndResumed()
    }

    func testRecorderStartFailureEndsActivity() async {
        recorder.startError.set(PushToTalkRecorder.RecorderError.microphonePermissionDenied)
        press(at: 1000)
        await coordinator.waitUntilSettled()
        assertSettledAndResumed()
    }

    func testRecorderStopFailureEndsActivity() async {
        press(at: 1000)
        await coordinator.waitUntilSettled()
        recorder.recording.set(false) // stop() が notRecording を投げる
        release(at: 1001.5, held: 1.5)
        await coordinator.waitUntilSettled()
        XCTAssertTrue(store.records.get().isEmpty)
        assertSettledAndResumed()
    }

    func testNoSpeechEndsActivity() async {
        stt.handler.set { _, _ in throw STTError.noSpeech(reason: .silent) }
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001.5, held: 1.5)
        await coordinator.waitUntilSettled()
        assertSettledAndResumed()
    }

    func testTranscriptionFailureEndsActivity() async {
        stt.handler.set { _, _ in throw STTError.engineFailure("x") }
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001.5, held: 1.5)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(store.records.get().count, 1, "音声を残して保存")
        assertSettledAndResumed()
    }

    func testInsertFailureEndsActivity() async {
        store.insertError.set(CocoaError(.fileWriteOutOfSpace))
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001.5, held: 1.5)
        await coordinator.waitUntilSettled()
        assertSettledAndResumed()
    }

    func testHotKeyResetEndsActivity() async {
        press(at: 1000)
        await coordinator.waitUntilSettled()
        clock.set(1002)
        coordinator.endActiveRecordingForHotKeyReset()
        await coordinator.waitUntilSettled()
        assertSettledAndResumed()
    }

    func testOverlappingCapturesStayActiveUntilBothAreSaved() async {
        let gate = Box(false)
        stt.handler.set { _, _ in
            while !gate.get() { try await Task.sleep(for: .milliseconds(5)) }
            return Transcript(text: "メモ", engine: "e")
        }
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001, held: 1)
        await waitForPhase(.idle)
        // 1 件目の文字起こし中に 2 件目を押す。
        press(at: 1002)
        await waitForPhase(.recording)
        XCTAssertEqual(coordinator.activeCaptures, 2)
        gate.set(true)
        // 1 件目が保存されても、2 件目を録音中なのでキャプチャ中のまま。
        let deadline = ContinuousClock.now + .seconds(3)
        while store.records.get().count < 1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.records.get().count, 1)
        XCTAssertEqual(activity, [true])
        release(at: 1003, held: 1)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(store.records.get().count, 2)
        assertSettledAndResumed()
    }

    func testRetryTranscriptionIsActiveWhileRunning() async throws {
        stt.handler.set { _, _ in throw STTError.engineFailure("x") }
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001.5, held: 1.5)
        await coordinator.waitUntilSettled()
        let id = try XCTUnwrap(store.records.get().keys.first)
        activity = []
        let during = Box<[Bool]>([])
        stt.handler.set { [unowned self] _, _ in
            let a = await MainActor.run { self.activity }
            during.set(a)
            return Transcript(text: "再試行", engine: "e")
        }
        await coordinator.retryTranscription(recordID: id)
        XCTAssertEqual(during.get(), [true], "再試行の文字起こし中もキャプチャ中")
        assertSettledAndResumed()
    }

    // MARK: - TriageWiring: 順番どおりにキューへ渡す

    func testWiringForwardsActivityInOrder() async {
        let queue = RecordingPauseQueue()
        let wiring = TriageWiring(queue: queue)
        for _ in 0..<50 {
            wiring.captureActivityChanged(true)
            wiring.captureActivityChanged(false)
        }
        await wiring.waitForCaptureActivityForwarded()
        let got = queue.states.get()
        XCTAssertEqual(got.count, 100)
        XCTAssertEqual(got, Array(repeating: [true, false], count: 50).flatMap { $0 }, "pause / resume の順が入れ替わらない")
    }

    // MARK: - 本物の TriageQueue と組み合わせる

    func testRealQueueDoesNotStartStepsWhileCapturing() async throws {
        let triageStore = TestStore()
        defer { try? FileManager.default.removeItem(at: triageStore.root) }
        let classifier = FakeClassifier()
        let queue = TriageQueue(store: triageStore, classifier: classifier, scanner: FakeScanner(),
                                embedder: FakeTriageEmbedder(), screenshots: FakeScreenshotLoader())
        let wiring = TriageWiring(queue: queue)
        coordinator.onCaptureActivityChanged = { [unowned self] active in
            activity.append(active)
            wiring.captureActivityChanged(active)
        }
        let earlier = ContextRecord(capturedAt: Date(), app: .unknown, annotation: Annotation(text: "前の記録", sttEngine: "e"))
        try await triageStore.insert(earlier)

        let gate = Box(false)
        stt.handler.set { _, _ in
            while !gate.get() { try await Task.sleep(for: .milliseconds(5)) }
            return Transcript(text: "メモ", engine: "e")
        }
        press(at: 1000)
        await coordinator.waitUntilSettled()
        await wiring.waitForCaptureActivityForwarded()
        // キャプチャ中に前の記録のトリアージが積まれても始まらない。
        await queue.enqueue(id: earlier.id)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(classifier.calls.get(), 0, "キャプチャ中は次のステップを始めない")
        let paused = await queue.isPaused
        XCTAssertTrue(paused)

        release(at: 1001.5, held: 1.5)
        gate.set(true)
        await coordinator.waitUntilSettled()
        await wiring.waitForCaptureActivityForwarded()
        await queue.waitUntilIdle()
        XCTAssertEqual(classifier.calls.get(), 1, "保存後に再開して処理する")
        let stillPaused = await queue.isPaused
        XCTAssertFalse(stillPaused)
        assertSettledAndResumed()
    }
}

/// `setCapturing` の呼ばれた順を残すキュー。
private final class RecordingPauseQueue: TriageQueuing, @unchecked Sendable {
    let states = Box<[Bool]>([])
    func enqueue(id: String) async {}
    func annotationEdited(id: String) async {}
    func reindex(id: String) async {}
    func resumePending() async throws -> Int { 0 }
    func waitUntilIdle() async {}
    func setCapturing(_ capturing: Bool) async {
        // 少し待たせて、Task の到着順が入れ替わりうる状況にする。
        if capturing { try? await Task.sleep(for: .microseconds(200)) }
        states.update { $0.append(capturing) }
    }
}

/// 呼ばれた回数だけ数える埋め込み（CCTriage.Embedder）。
private struct FakeTriageEmbedder: Embedder {
    let dimension = 4
    func embedQuery(_ text: String) async throws -> [Float] { [1, 0, 0, 0] }
    func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] { [1, 0, 0, 0] }
}
