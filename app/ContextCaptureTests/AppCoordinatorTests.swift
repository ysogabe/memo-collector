import CCCapture
import CCCore
import CCSTT
import XCTest

/// AppCoordinator の状態機械と保存の流れ（部品はすべてフェイク。権限・ハードウェアには触らない）。
@MainActor
final class AppCoordinatorTests: XCTestCase {
    private var capturer: FakeCapturer!
    private var recorder: FakeRecorder!
    private var stt: FakeTranscriber!
    private var store: TestStore!
    private var clock: Box<TimeInterval>!
    private var coordinator: AppCoordinator!
    private var events: AsyncStream<CaptureEvent>.Iterator!
    private var saved: [String] = []
    private var removed: [String] = []
    private var retried: [String] = []

    override func setUp() async throws {
        capturer = FakeCapturer.standard()
        recorder = FakeRecorder()
        stt = FakeTranscriber()
        store = TestStore()
        clock = Box(1000)
        make()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: store.root)
    }

    private func make(maxRecording: Duration = .seconds(120)) {
        let clock = clock!
        coordinator = AppCoordinator(dependencies: CaptureDependencies(
            capturer: capturer, recorder: recorder, transcriber: stt, store: store,
            vocabulary: { ["Hermes", "Claude Code"] },
            uptime: { clock.get() },
            maxRecordingDuration: maxRecording
        ))
        coordinator.onRecordSaved = { [unowned self] in saved.append($0) }
        coordinator.onRecordRemoved = { [unowned self] in removed.append($0) }
        coordinator.onTranscriptRetried = { [unowned self] in retried.append($0) }
        events = coordinator.events().makeAsyncIterator()
        saved = []
        removed = []
        retried = []
    }

    // MARK: - 補助

    private func press(at t: TimeInterval = 1000) {
        coordinator.handle(HotKeyEvent(kind: .pressed, uptime: t, date: Date()))
    }

    private func release(at t: TimeInterval, held: TimeInterval) {
        clock.set(t)
        coordinator.handle(HotKeyEvent(kind: .released, uptime: t, date: Date(), pressDuration: held))
    }

    private func expect(_ name: String, file: StaticString = #filePath, line: UInt = #line) async {
        let got = await nextName()
        XCTAssertEqual(got, name, file: file, line: line)
    }

    private func next() async -> CaptureEvent? {
        // 反復子は中身（バッファ）を共有する参照なので、ローカルに写して進めて戻す。
        var it = events!
        let e = await it.next()
        events = it
        return e
    }

    /// 次のイベントの種類を名前で（比較しやすくする）。
    private func nextName() async -> String {
        guard let e = await next() else { return "end" }
        return Self.name(e)
    }

    static func name(_ e: CaptureEvent) -> String {
        switch e {
        case .recordingStarted: return "started"
        case .recordingEnded: return "ended"
        case .recordingDiscarded: return "discarded"
        case .saved: return "saved"
        case let .failed(f):
            switch f {
            case .noVoice: return "failed.noVoice"
            case .recordingInterrupted: return "failed.interrupted"
            case .transcriptionFailed: return "failed.transcription"
            case .microphoneUnavailable: return "failed.microphone"
            case .saveFailed: return "failed.save"
            }
        }
    }

    private func waitForPhase(_ p: AppCoordinator.Phase, timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        while coordinator.phase != p, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(coordinator.phase, p)
    }

    /// 長押し 1 回分（押下 → 録音開始 → 解放 → 保存まで）を流し、保存イベントの記録を返す。
    @discardableResult
    private func captureOnce(held: TimeInterval = 1.5) async -> ContextRecord? {
        press(at: clock.get())
        await coordinator.waitUntilSettled()
        release(at: clock.get() + held, held: held)
        await coordinator.waitUntilSettled()
        await expect("started")
        await expect("ended")
        guard case let .saved(r, _)? = await next() else { XCTFail("not saved"); return nil }
        return r
    }

    func testInterruptedRecordingPreservesPartialAudioAndReportsBothNotices() async throws {
        recorder.interrupted.set(true)
        var context = capturer.context.get()
        context.screenshot = nil
        context.screenshotSkipReason = ScreenshotSkipReason.permissionDenied
        capturer.context.set(context)
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001, held: 1)
        await coordinator.waitUntilSettled()
        await expect("started"); await expect("ended")
        guard case let .saved(record, notice)? = await next() else { return XCTFail("partial recording should be saved") }
        XCTAssertEqual(notice, .recordingInterruptedAndScreenRecordingDenied)
        XCTAssertEqual(record.extra["recording_interrupted"], "true")
        XCTAssertNotNil(record.audioPath)
        XCTAssertEqual(record.annotation.text, "このissueの修正、Claude Codeにやらせて")
    }

    private actor RetryGate {
        private var reply: CheckedContinuation<Transcript, Never>?
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0
        func request() async -> Transcript {
            calls += 1
            return await withCheckedContinuation { continuation in
                reply = continuation
                let waiting = waiters; waiters = []
                for waiter in waiting { waiter.resume() }
            }
        }
        func waitUntilStarted() async {
            if reply != nil { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            reply?.resume(returning: Transcript(text: "retry transcript", engine: "fixture"))
            reply = nil
        }
    }

    private func insertRetryRecord() async throws -> ContextRecord {
        var record = ContextRecord(id: "retry-fixture", capturedAt: Date(timeIntervalSince1970: 1), app: .unknown,
                                   annotation: Annotation(text: "", sttEngine: nil))
        let wav = try AudioFileIO.wavData(samples: Array(repeating: 0.1, count: 16000))
        record.audioPath = try await store.writeAttachment(wav, id: record.id, kind: .audio, ext: "wav", capturedAt: record.capturedAt)
        try await store.insert(record)
        return record
    }

    func testConcurrentRetryOnlyTranscribesOnce() async throws {
        let record = try await insertRetryRecord(), gate = RetryGate()
        stt.handler.set { _, _ in await gate.request() }
        let first = Task { await coordinator.retryTranscription(recordID: record.id) }
        await gate.waitUntilStarted()
        await coordinator.retryTranscription(recordID: record.id)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        await gate.release(); await first.value
        XCTAssertEqual(retried, [record.id])
        let updated = try await store.get(id: record.id)
        XCTAssertEqual(updated?.annotation.text, "retry transcript")
    }

    func testUndoDuringRetryDoesNotResurrectRecordOrPublishSaved() async throws {
        let record = try await insertRetryRecord(), gate = RetryGate()
        stt.handler.set { _, _ in await gate.request() }
        let retry = Task { await coordinator.retryTranscription(recordID: record.id) }
        await gate.waitUntilStarted()
        try await coordinator.undo(recordID: record.id)
        await gate.release(); await retry.value
        let missing = try await store.get(id: record.id)
        XCTAssertNil(missing)
        XCTAssertTrue(retried.isEmpty)
        XCTAssertEqual(removed, [record.id])
        XCTAssertEqual(store.attachmentFileCount(), 0)
    }

    func testHotKeyResetWhileStartingHandlesPendingRelease() async {
        recorder.startDelay.set(.milliseconds(20))
        press(at: 1000)
        XCTAssertEqual(coordinator.phase, .starting)
        clock.set(1001)
        coordinator.endActiveRecordingForHotKeyReset()
        await coordinator.waitUntilSettled()
        await expect("started"); await expect("ended"); await expect("saved")
        XCTAssertEqual(store.records.get().count, 1)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testScreenshotWriteFailureStillSavesTranscriptAndAudio() async throws {
        store.attachmentWriteFailures.set([.screenshot])
        let captured = await captureOnce()
        let record = try XCTUnwrap(captured)
        XCTAssertNil(record.screenshotPath)
        XCTAssertNotNil(record.audioPath)
        XCTAssertFalse(record.annotation.text.isEmpty)
        XCTAssertEqual(store.attachmentFileCount(), 1)
    }

    func testAudioWriteFailureStillSavesTranscriptAndRemovesTemporaryAudio() async throws {
        store.attachmentWriteFailures.set([.audio])
        let captured = await captureOnce()
        let record = try XCTUnwrap(captured)
        XCTAssertNil(record.audioPath)
        XCTAssertNotNil(record.screenshotPath)
        XCTAssertFalse(record.annotation.text.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(recorder.lastFileURL.get()).path))
    }

    func testInterruptedSilentRecordingReportsInterruptionRatherThanNoVoice() async {
        recorder.interrupted.set(true)
        stt.handler.set { _, _ in throw STTError.noSpeech(reason: .silent) }
        press(at: 1000); await coordinator.waitUntilSettled()
        release(at: 1001, held: 1); await coordinator.waitUntilSettled()
        await expect("started"); await expect("ended"); await expect("failed.interrupted")
        XCTAssertTrue(store.records.get().isEmpty)
        XCTAssertEqual(store.attachmentFileCount(), 0)
    }

    // MARK: - 正常系

    func testLongPressSavesRecordWithScreenshotAndAudio() async throws {
        press(at: 1000)
        XCTAssertEqual(coordinator.phase, .starting)
        clock.set(1000.08)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(coordinator.phase, .recording)
        XCTAssertEqual(recorder.log.get(), ["levels", "start"], "レベルの購読は start より先")
        XCTAssertEqual(capturer.calls.get(), 1)
        await expect("started")

        release(at: 1001.5, held: 1.5)
        XCTAssertEqual(coordinator.phase, .stopping)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(coordinator.phase, .idle)
        await expect("ended")
        guard case let .saved(record, notice)? = await next() else { return XCTFail("not saved") }
        XCTAssertNil(notice)

        XCTAssertEqual(record.annotation.text, "このissueの修正、Claude Codeにやらせて")
        XCTAssertEqual(record.annotation.sttEngine, "whisperkit-large-v3-turbo")
        XCTAssertEqual(record.app, AppInfo(name: "Google Chrome", bundleID: "com.google.Chrome"))
        XCTAssertEqual(record.window?.title, "Issue #128")
        XCTAssertEqual(record.url, "https://github.com/opendots/opendots/issues/128")
        XCTAssertEqual(record.guardInfo.status, .pending)
        XCTAssertEqual(record.status, .inbox)
        // 日時はミリ秒に丸める（DB の精度に合わせる）。
        XCTAssertEqual(record.capturedAt.timeIntervalSince1970, 1_791_000_000.123, accuracy: 1e-9)
        XCTAssertEqual(ULID(string: record.id)?.timestamp.timeIntervalSince1970 ?? 0, 1_791_000_000.123, accuracy: 0.001)

        let ext = ScreenshotEncoder.chosenFormat!.fileExtension
        XCTAssertEqual(record.screenshotPath.map { ($0 as NSString).pathExtension }, ext)
        XCTAssertEqual(record.audioPath.map { ($0 as NSString).pathExtension }, "wav")
        let stored = try await store.get(id: record.id)
        XCTAssertEqual(stored, record)
        XCTAssertEqual(store.attachmentFileCount(), 2)
        XCTAssertEqual(stt.calls.get(), [["Hermes", "Claude Code"]], "語彙は設定から渡す")
        XCTAssertEqual(saved, [record.id], "保存直後のフック（M2 のトリアージ）")
        // 録音器の一時 WAV は添付へ写したら消す。
        let tmp = try XCTUnwrap(recorder.lastFileURL.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))

        let pressMs = try XCTUnwrap(coordinator.latency.samples[.pressToRecording]?.values.first)
        XCTAssertEqual(pressMs, 80, accuracy: 0.5)
        XCTAssertEqual(coordinator.latency.samples[.releaseToSaved]?.count, 1)
    }

    func testShortPressIsDiscardedSilently() async {
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1000.2, held: 0.2)
        await coordinator.waitUntilSettled()
        await expect("started")
        await expect("discarded")
        XCTAssertEqual(recorder.log.get(), ["levels", "start", "cancel"])
        XCTAssertTrue(stt.calls.get().isEmpty)
        XCTAssertTrue(store.records.get().isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testReleaseBeforeRecorderStartedIsHandledAfterStart() async {
        recorder.startDelay.set(.milliseconds(100))
        press(at: 1000)
        release(at: 1000.5, held: 0.5)    // start() の完了前に解放が届く
        XCTAssertEqual(coordinator.phase, .starting)
        await coordinator.waitUntilSettled()
        await expect("started")
        await expect("ended")
        await expect("saved")
        XCTAssertEqual(recorder.log.get(), ["levels", "start", "stop"])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testShortReleaseBeforeRecorderStartedIsDiscarded() async {
        recorder.startDelay.set(.milliseconds(100))
        press(at: 1000)
        release(at: 1000.1, held: 0.1)
        await coordinator.waitUntilSettled()
        await expect("started")
        await expect("discarded")
        XCTAssertEqual(recorder.log.get(), ["levels", "start", "cancel"])
        XCTAssertFalse(recorder.recording.get())
    }

    func testRepeatedPressWhileRecordingIsIgnored() async {
        press(at: 1000)
        press(at: 1000.01)          // 二重配送
        await coordinator.waitUntilSettled()
        press(at: 1000.5)           // 録音中の再押下
        await coordinator.waitUntilSettled()
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(capturer.calls.get(), 1)
        release(at: 1002, held: 2)
        press(at: 1002.001)         // stopping 中の押下
        await coordinator.waitUntilSettled()
        await expect("started")
        await expect("ended")
        await expect("saved")
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(store.records.get().count, 1)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testUnpairedReleaseIsIgnored() async {
        release(at: 1000, held: 1)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(recorder.log.get().isEmpty)
        // 壊れていない: 次の押下は普通に通る。
        let r = await captureOnce()
        XCTAssertNotNil(r)
    }

    func testNextPressIsAcceptedWhilePreviousIsTranscribing() async throws {
        let gate = Box(false)
        stt.handler.set { _, _ in
            while !gate.get() { try await Task.sleep(for: .milliseconds(5)) }
            return Transcript(text: "一件目", engine: "e")
        }
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001, held: 1)
        await waitForPhase(.idle)
        await expect("started")
        await expect("ended")
        // 1 件目の文字起こし中に 2 件目を押す。
        press(at: 1002)
        await waitForPhase(.recording)
        await expect("started")
        gate.set(true)
        await expect("saved")
        release(at: 1003, held: 1)
        await coordinator.waitUntilSettled()
        await expect("ended")
        await expect("saved")
        XCTAssertEqual(store.records.get().count, 2)
        XCTAssertEqual(capturer.calls.get(), 2)
    }

    func testLostReleaseIsRecoveredByWatchdog() async {
        make(maxRecording: .milliseconds(50))
        press(at: 1000)
        await coordinator.waitUntilSettled()
        await expect("started")
        clock.set(1010)
        await expect("ended")
        await expect("saved")
        await coordinator.waitUntilSettled()
        XCTAssertEqual(coordinator.phase, .idle)
        // あとから届いた本物の解放は無視される。
        release(at: 1011, held: 11)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testHotKeyResetWhileRecordingSavesWhatWasRecorded() async {
        press(at: 1000)
        await coordinator.waitUntilSettled()
        clock.set(1002)
        coordinator.endActiveRecordingForHotKeyReset()
        await coordinator.waitUntilSettled()
        await expect("started")
        await expect("ended")
        await expect("saved")
    }

    // MARK: - 失敗系（PRD §6.3）

    func testNoSpeechCreatesNoRecordAndLeavesNoFiles() async throws {
        stt.handler.set { _, _ in throw STTError.noSpeech(reason: .silent) }
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001.5, held: 1.5)
        await coordinator.waitUntilSettled()
        await expect("started")
        await expect("ended")
        await expect("failed.noVoice")
        XCTAssertTrue(store.records.get().isEmpty)
        XCTAssertEqual(store.attachmentFileCount(), 0)
        XCTAssertTrue(saved.isEmpty)
        let tmp = try XCTUnwrap(recorder.lastFileURL.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testTranscriptionFailureKeepsAudioAndRetrySucceeds() async throws {
        stt.handler.set { _, _ in throw STTError.engineFailure("ANE busy") }
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1002, held: 2)
        await coordinator.waitUntilSettled()
        await expect("started")
        await expect("ended")
        guard case let .failed(.transcriptionFailed(id))? = await next() else { return XCTFail("expected transcriptionFailed") }
        let fetched = try await store.get(id: id)
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.annotation.text, "")
        XCTAssertNil(record.annotation.sttEngine)
        XCTAssertNotNil(record.audioPath)
        XCTAssertNotNil(record.screenshotPath)
        // 注釈が無くてもトリアージに回す（ガードと索引。意図は注釈が空なのでトリアージ側でスキップされる）。
        XCTAssertEqual(saved, [id], "STT に失敗した記録もガードと索引に回す")
        XCTAssertTrue(retried.isEmpty)
        XCTAssertNil(coordinator.latency.samples[.releaseToSaved])

        // [再試行]: 保存した WAV を読み直して文字起こしする。
        let received = Box(0)
        stt.handler.set { samples, _ in
            received.set(samples.count)
            return Transcript(text: "やり直した文字起こし", engine: "whisperkit-large-v3-turbo")
        }
        await coordinator.retryTranscription(recordID: id)
        guard case let .saved(updated, _)? = await next() else { return XCTFail("retry not saved") }
        XCTAssertEqual(updated.id, id)
        XCTAssertEqual(updated.annotation.text, "やり直した文字起こし")
        XCTAssertEqual(received.get(), 16_000)
        let reread = try await store.get(id: id)
        XCTAssertEqual(reread?.annotation.text, "やり直した文字起こし")
        XCTAssertEqual(reread?.annotation.sttEngine, "whisperkit-large-v3-turbo")
        XCTAssertEqual(saved, [id], "再試行では enqueue し直さない（ガードは保存時に回してある）")
        XCTAssertEqual(retried, [id], "再試行が成功したら意図と索引をやり直す")
    }

    /// 再試行の保存は `modify`（1 トランザクション）で注釈だけを当てる。読み直しと保存の間に別の書き手（トリアージのガード・
    /// cc-mcp のメモ）が書いても消えない。
    func testRetryKeepsConcurrentGuardAndNotesWrites() async throws {
        let modifyStore = ModifyOnlyStore()
        defer { try? FileManager.default.removeItem(at: modifyStore.inner.root) }
        let clock = clock!
        coordinator = AppCoordinator(dependencies: CaptureDependencies(
            capturer: capturer, recorder: recorder, transcriber: stt, store: modifyStore,
            readAudio: { _ in Array(repeating: 0.1, count: 16_000) },
            uptime: { clock.get() }
        ))
        coordinator.onTranscriptRetried = { [unowned self] in retried.append($0) }
        events = coordinator.events().makeAsyncIterator()

        let audioPath = try await modifyStore.writeAttachment(Data([0]), id: "x", kind: .audio, ext: "wav", capturedAt: Date())
        let r = ContextRecord(capturedAt: Date(), app: .unknown, audioPath: audioPath,
                              annotation: Annotation(text: "", sttEngine: nil), guardInfo: GuardInfo(status: .pending))
        try await modifyStore.insert(r)
        // 保存（modify）の直前に、別の書き手がガードの結果とメモを書く。
        modifyStore.beforeModify.set { rec in
            rec.guardInfo = GuardInfo(status: .needsReview, findings: [])
            if rec.notes.isEmpty { rec.notes.append(Note(author: "claude-code", text: "メモ", at: Date(timeIntervalSince1970: 1_791_000_000))) }
        }
        stt.handler.set { _, _ in Transcript(text: "再試行の注釈", engine: "whisperkit-x") }
        await coordinator.retryTranscription(recordID: r.id)
        guard case let .saved(updated, _)? = await next() else { return XCTFail("retry not saved") }
        XCTAssertEqual(modifyStore.modifyCalls.get(), 1, "get + update ではなく modify で保存する")
        let reread = try await modifyStore.get(id: r.id)
        XCTAssertEqual(reread?.annotation.text, "再試行の注釈")
        XCTAssertEqual(reread?.annotation.sttEngine, "whisperkit-x")
        XCTAssertEqual(reread?.guardInfo.status, .needsReview, "別の書き手のガードを巻き戻さない")
        XCTAssertEqual(reread?.notes.count, 1, "別の書き手のメモを消さない")
        XCTAssertEqual(updated.notes.count, 1, "保存イベントの記録も最新")
        XCTAssertEqual(retried, [r.id])
    }

    /// `RecordModifying` でないストアでは get + update（詳細ビューと同じ）。消えた記録は作り直さない。
    func testRetryOnNonModifyingStoreUsesGetAndUpdate() async throws {
        let plain = PlainStore()
        defer { try? FileManager.default.removeItem(at: plain.inner.root) }
        let r = ContextRecord(capturedAt: Date(), app: .unknown, audioPath: "a.wav",
                              annotation: Annotation(text: "", sttEngine: nil))
        try await plain.insert(r)
        var t = Transcript(text: "注釈", engine: "e")
        let updated = try await AppCoordinator.applyRetriedTranscript(t, id: r.id, store: plain)
        XCTAssertEqual(updated.annotation.text, "注釈")
        XCTAssertEqual(plain.updateCalls.get(), 1)
        try await plain.delete(id: r.id)
        t.text = "x"
        do {
            _ = try await AppCoordinator.applyRetriedTranscript(t, id: r.id, store: plain)
            XCTFail("消えた記録は throw")
        } catch {}
        let missing = try await plain.get(id: r.id)
        XCTAssertNil(missing)
    }

    func testRetryWithoutAudioReportsFailureAgain() async throws {
        let r = ContextRecord(capturedAt: Date(), app: .unknown, annotation: Annotation(text: "", sttEngine: nil))
        try await store.insert(r)
        await coordinator.retryTranscription(recordID: r.id)
        await expect("failed.transcription")
    }

    func testMicrophoneUnavailable() async {
        recorder.startError.set(PushToTalkRecorder.RecorderError.microphonePermissionDenied)
        press(at: 1000)
        await coordinator.waitUntilSettled()
        await expect("failed.microphone")
        XCTAssertEqual(coordinator.phase, .idle)
        release(at: 1001, held: 1)   // 失敗後の解放は無視
        await coordinator.waitUntilSettled()
        XCTAssertTrue(store.records.get().isEmpty)
        // 権限が付いたら次の押下は通る。
        recorder.startError.set(nil)
        let r = await captureOnce()
        XCTAssertNotNil(r)
    }

    func testScreenRecordingDeniedSavesWithNotice() async throws {
        capturer.context.update {
            $0.screenshot = nil
            $0.screenshotSkipReason = ScreenshotSkipReason.permissionDenied
        }
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001, held: 1)
        await coordinator.waitUntilSettled()
        await expect("started")
        await expect("ended")
        guard case let .saved(r, notice)? = await next() else { return XCTFail("not saved") }
        XCTAssertEqual(notice, .screenRecordingDenied)
        XCTAssertNil(r.screenshotPath)
        XCTAssertNotNil(r.audioPath)
    }

    func testExcludedAppSavesWithoutNotice() async throws {
        capturer.context.update {
            $0.screenshot = nil
            $0.screenshotSkipReason = ScreenshotSkipReason.excludedApp
        }
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001, held: 1)
        await coordinator.waitUntilSettled()
        _ = await next(); _ = await next()
        guard case let .saved(r, notice)? = await next() else { return XCTFail("not saved") }
        XCTAssertNil(notice)
        XCTAssertNil(r.screenshotPath)
    }

    func testMissingAppFallsBackToUnknown() async throws {
        capturer.context.update { $0.app = nil; $0.window = nil; $0.url = nil }
        let captured = await captureOnce()
        let r = try XCTUnwrap(captured)
        XCTAssertEqual(r.app, .unknown)
    }

    func testInsertFailureRemovesWrittenAttachments() async {
        store.insertError.set(CocoaError(.fileWriteOutOfSpace))
        press(at: 1000)
        await coordinator.waitUntilSettled()
        release(at: 1001, held: 1)
        await coordinator.waitUntilSettled()
        await expect("started")
        await expect("ended")
        await expect("failed.save")
        XCTAssertEqual(store.attachmentFileCount(), 0)
    }

    func testRecorderWithoutFileStillSavesWAV() async throws {
        recorder.writesFile.set(false)
        let captured = await captureOnce()
        let r = try XCTUnwrap(captured)
        let url = try await store.attachmentURL(for: try XCTUnwrap(r.audioPath))
        let samples = try AudioFileIO.readMono16k(url: url)
        XCTAssertEqual(samples.count, 16_000)
    }

    // MARK: - 取り消し

    func testUndoDeletesRecordAndAttachments() async throws {
        let captured = await captureOnce()
        let r = try XCTUnwrap(captured)
        XCTAssertEqual(store.attachmentFileCount(), 2)
        try await coordinator.undo(recordID: r.id)
        let after = try await store.get(id: r.id)
        XCTAssertNil(after)
        XCTAssertEqual(store.attachmentFileCount(), 0)
        XCTAssertEqual(removed, [r.id])
    }
}

/// `RecordModifying` に準拠しないストア（get + update の経路を確かめる）。
final class PlainStore: RecordStore, @unchecked Sendable {
    let inner = TestStore()
    let updateCalls = Box(0)
    func insert(_ record: ContextRecord) async throws { try await inner.insert(record) }
    func update(_ record: ContextRecord) async throws {
        updateCalls.update { $0 += 1 }
        try await inner.update(record)
    }
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
}
