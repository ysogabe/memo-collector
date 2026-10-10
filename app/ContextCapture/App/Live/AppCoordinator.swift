import CCCapture
import CCCore
import CCSTT
import CoreGraphics
import Foundation
import os

/// AppCoordinator が使う部品。すべて CCCore のプロトコル越しなので、テストではフェイクに差し替える。
struct CaptureDependencies {
    var capturer: any ContextCapturing
    var recorder: any AudioRecording
    var transcriber: any SpeechTranscribing
    var store: any RecordStore
    /// 文字起こしに渡す語彙（設定から毎回読む。設定変更がすぐ効く）。
    var vocabulary: @Sendable () -> [String] = { [] }
    /// スクショのエンコード（WebP → HEIC → PNG のうち書けるもの）。
    var encodeScreenshot: @Sendable (CGImage) -> EncodedImage? = { ScreenshotEncoder.encode($0) }
    /// 保存済みの音声を 16kHz モノラルで読む（再試行用）。
    var readAudio: @Sendable (URL) throws -> [Float] = { try AudioFileIO.readMono16k(url: $0) }
    /// `HotKeyEvent.uptime` と同じ時計。
    var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// 解放が届かなかったときの保険。これを超えて押しっぱなしなら解放とみなして保存する。
    var maxRecordingDuration: Duration = .seconds(120)
}

/// 録音〜保存の縦串（M1、PRD F-02〜F-06）。`CaptureControlling` の本物。
///
/// 状態機械:
/// ```
/// idle ──押下──▶ starting ──start() 完了──▶ recording ──解放──▶ stopping ──stop()/cancel() 完了──▶ idle
///                  │  └─解放（start() の完了待ち。完了後すぐ stopping へ）       （保存は別 Task で続く）
///                  └─start() が throw ─▶ idle（.failed(.microphoneUnavailable)）
/// ```
/// - 押下: 撮影（`captureFrontmost`）を**先に**起動し、録音（`start`）と並行させる。HUD（`.recordingStarted`）は録音開始後。
///   撮影は押下時点のウインドウを撮るため await しない（最大 1.5 秒）。結果は解放後の保存で待つ。
/// - idle 以外での押下（キーリピート・二重配送・stopping 中の再押下）は無視。idle / stopping での解放（対の無い解放）も無視。
/// - stop() が返った時点で idle に戻すので、前の記録の文字起こし中（1〜2 秒）でも次の押下を受けられる。
/// - 解放が届かない（ホットキーの登録し直し・OS の取りこぼし）ときは `maxRecordingDuration` で解放とみなす。
@MainActor
final class AppCoordinator: CaptureControlling {
    enum Phase: String, Sendable {
        case idle, starting, recording, stopping
    }

    /// 1 回の押下〜解放。
    private final class Session {
        let pressUptime: TimeInterval
        let captureTask: Task<CaptureContext, Never>
        let signpost: OSSignpostIntervalState
        /// starting 中に届いた解放（start() の完了後に処理する）。
        var pendingRelease: HotKeyEvent?
        var watchdog: Task<Void, Never>?

        init(pressUptime: TimeInterval, captureTask: Task<CaptureContext, Never>, signpost: OSSignpostIntervalState) {
            self.pressUptime = pressUptime
            self.captureTask = captureTask
            self.signpost = signpost
        }
    }

    private enum State {
        case idle
        case starting(Session)
        case recording(Session)
        case stopping
    }

    private let deps: CaptureDependencies
    let latency: CaptureLatencyMonitor
    /// 保存した直後（文字起こしの再試行で注釈が入ったときも）に呼ぶ。**M2 で `TriageQueue.enqueue(id:)` をここに差す**。
    var onRecordSaved: @MainActor (String) -> Void = { _ in }
    /// 取り消しで記録を消した直後に呼ぶ。M2 でトリアージの取り消し（キューから外す）をここに差す。
    var onRecordRemoved: @MainActor (String) -> Void = { _ in }

    private nonisolated let stream: AsyncStream<CaptureEvent>
    private nonisolated let continuation: AsyncStream<CaptureEvent>.Continuation
    private var state: State = .idle
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var retrying: Set<String> = []

    init(dependencies: CaptureDependencies, latency: CaptureLatencyMonitor? = nil) {
        deps = dependencies
        self.latency = latency ?? CaptureLatencyMonitor()
        (stream, continuation) = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        continuation.finish()
    }

    var phase: Phase {
        switch state {
        case .idle: return .idle
        case .starting: return .starting
        case .recording: return .recording
        case .stopping: return .stopping
        }
    }

    // MARK: - CaptureControlling

    nonisolated func events() -> AsyncStream<CaptureEvent> { stream }

    func undo(recordID: String) async throws {
        try await deps.store.delete(id: recordID)
        CCLog.capture.info("undo \(recordID, privacy: .public)")
        onRecordRemoved(recordID)
    }

    func retryTranscription(recordID: String) async {
        guard !retrying.contains(recordID) else { return }
        retrying.insert(recordID)
        defer { retrying.remove(recordID) }
        guard let record = try? await deps.store.get(id: recordID), let audioPath = record.audioPath,
              let url = try? await deps.store.attachmentURL(for: audioPath)
        else {
            CCLog.capture.error("retry: record or audio missing \(recordID, privacy: .public)")
            emit(.failed(.transcriptionFailed(recordID: recordID)))
            return
        }
        let samples: [Float]
        do { samples = try deps.readAudio(url) } catch {
            CCLog.capture.error("retry: audio unreadable \(String(describing: error), privacy: .public)")
            emit(.failed(.transcriptionFailed(recordID: recordID)))
            return
        }
        let transcript: Transcript
        do {
            transcript = try await deps.transcriber.transcribe(samples: samples, vocabulary: deps.vocabulary())
        } catch STTError.noSpeech {
            emit(.failed(.noVoice))
            return
        } catch {
            CCLog.capture.error("retry: stt failed \(String(describing: error), privacy: .public)")
            emit(.failed(.transcriptionFailed(recordID: recordID)))
            return
        }
        // 再試行の間にユーザーが詳細で手直ししていたら、その記録を読み直して注釈だけを差し替える。
        var updated = (try? await deps.store.get(id: recordID)) ?? record
        updated.annotation = Annotation(text: transcript.text, sttEngine: transcript.engine)
        do {
            try await deps.store.update(updated)
        } catch {
            emit(.failed(.saveFailed(detail: String(describing: error))))
            return
        }
        emit(.saved(updated, notice: nil))
        onRecordSaved(recordID)
    }

    // MARK: - ホットキー

    /// ホットキーの押下 / 解放（メインスレッドで `GlobalPushToTalkHotKey.onEvent` から呼ぶ）。
    func handle(_ event: HotKeyEvent) {
        switch event.kind {
        case .pressed: press(event)
        case .released: release(event)
        }
    }

    /// ホットキーを登録し直す前に呼ぶ（`GlobalPushToTalkHotKey.stop()` は押下中でも解放を流さないため）。
    /// 録音中ならその時点で解放されたものとして保存へ進める。
    func endActiveRecordingForHotKeyReset() {
        switch state {
        case let .starting(s), let .recording(s):
            CCLog.capture.notice("hotkey reset while \(self.phase.rawValue, privacy: .public): treating as release")
            release(syntheticRelease(for: s))
        case .idle, .stopping:
            break
        }
    }

    private func press(_ e: HotKeyEvent) {
        guard case .idle = state else {
            CCLog.capture.debug("press ignored (\(self.phase.rawValue, privacy: .public))")
            return
        }
        // 押下時点のウインドウを撮るため、録音開始・HUD より先に撮影を始める（待たない）。
        let capturer = deps.capturer
        let captureTask = Task.detached(priority: .userInitiated) { await capturer.captureFrontmost() }
        let session = Session(pressUptime: e.uptime, captureTask: captureTask,
                              signpost: CCLog.signposter.beginInterval("pressToRecording"))
        state = .starting(session)
        spawn { await self.beginRecording(session) }
    }

    private func release(_ e: HotKeyEvent) {
        switch state {
        case .idle, .stopping:
            CCLog.capture.debug("unpaired release ignored (\(self.phase.rawValue, privacy: .public))")
        case let .starting(s):
            s.pendingRelease = e
        case let .recording(s):
            finishRecording(s, release: e)
        }
    }

    private func beginRecording(_ s: Session) async {
        // レベルの購読は start() より先に（始まった直後の値を落とさない）。
        let levels = await deps.recorder.levels()
        do {
            try await deps.recorder.start()
        } catch {
            CCLog.signposter.endInterval("pressToRecording", s.signpost)
            CCLog.capture.error("recorder.start failed: \(String(describing: error), privacy: .public)")
            s.captureTask.cancel()
            if isCurrent(s) { state = .idle }
            emit(.failed(.microphoneUnavailable))
            return
        }
        CCLog.signposter.endInterval("pressToRecording", s.signpost)
        latency.record(.pressToRecording, milliseconds: max(0, (deps.uptime() - s.pressUptime) * 1000))
        guard isCurrent(s) else {
            await deps.recorder.cancel()
            return
        }
        state = .recording(s)
        emit(.recordingStarted(levels: levels))
        if let release = s.pendingRelease {
            finishRecording(s, release: release)
            return
        }
        let limit = deps.maxRecordingDuration
        s.watchdog = Task { [weak self, weak s] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, let s else { return }
            CCLog.capture.notice("release not delivered within \(String(describing: limit), privacy: .public): stopping")
            self.release(self.syntheticRelease(for: s))
        }
    }

    private func finishRecording(_ s: Session, release e: HotKeyEvent) {
        s.watchdog?.cancel()
        state = .stopping
        let duration = e.pressDuration ?? max(0, e.uptime - s.pressUptime)
        let discard = PushToTalkTiming.isTooShort(duration)
        spawn { await self.stopRecording(s, releaseUptime: e.uptime, discard: discard) }
    }

    private func stopRecording(_ s: Session, releaseUptime: TimeInterval, discard: Bool) async {
        if discard {
            await deps.recorder.cancel()
            s.captureTask.cancel()
            state = .idle
            emit(.recordingDiscarded)
            return
        }
        let audio: RecordedAudio
        do {
            audio = try await deps.recorder.stop()
        } catch {
            CCLog.capture.error("recorder.stop failed: \(String(describing: error), privacy: .public)")
            s.captureTask.cancel()
            state = .idle
            emit(.recordingEnded)
            emit(.failed(.microphoneUnavailable))
            return
        }
        state = .idle
        emit(.recordingEnded)
        let signpost = CCLog.signposter.beginInterval("releaseToSaved")
        await save(audio: audio, context: await s.captureTask.value, releaseUptime: releaseUptime)
        CCLog.signposter.endInterval("releaseToSaved", signpost)
    }

    // MARK: - 保存

    private func save(audio: RecordedAudio, context: CaptureContext, releaseUptime: TimeInterval) async {
        defer { removeTemporaryAudio(audio) }
        // エンコード（重い）は文字起こしと並行に。ファイルへの書き込みは「声が入っていた」と分かってから。
        let encode = deps.encodeScreenshot
        let encodeTask = Task.detached(priority: .userInitiated) { context.screenshot.flatMap(encode) }

        var transcript: Transcript?
        do {
            transcript = try await deps.transcriber.transcribe(samples: audio.samples16kMono, vocabulary: deps.vocabulary())
        } catch let STTError.noSpeech(reason) {
            CCLog.capture.info("no speech (\(reason.rawValue, privacy: .public)): record not created")
            encodeTask.cancel()
            emit(.failed(.noVoice))
            return
        } catch {
            // 音声を残して記録を作り、[再試行] を出す（PRD §6.3）。
            CCLog.capture.error("stt failed: \(String(describing: error), privacy: .public)")
        }

        let capturedAt = context.capturedAt.ccRoundedToMilliseconds
        let id = ULID.generate(now: capturedAt).string
        var written: [String] = []

        var screenshotPath: String?
        if let image = await encodeTask.value {
            do {
                let p = try await deps.store.writeAttachment(image.data, id: id, kind: .screenshot, ext: image.fileExtension, capturedAt: capturedAt)
                screenshotPath = p
                written.append(p)
            } catch {
                CCLog.store.error("screenshot write failed: \(String(describing: error), privacy: .public)")
            }
        } else if context.screenshot != nil {
            CCLog.capture.error("screenshot encode failed")
        }

        var audioPath: String?
        let audioData = audio.fileURL.flatMap { try? Data(contentsOf: $0) } ?? AudioFileIO.wavData(samples: audio.samples16kMono)
        do {
            let p = try await deps.store.writeAttachment(audioData, id: id, kind: .audio, ext: "wav", capturedAt: capturedAt)
            audioPath = p
            written.append(p)
        } catch {
            CCLog.store.error("audio write failed: \(String(describing: error), privacy: .public)")
        }

        let record = ContextRecord(
            id: id,
            capturedAt: capturedAt,
            app: context.app ?? .unknown,
            window: context.window,
            url: context.url,
            extra: context.extra,
            screenshotPath: screenshotPath,
            audioPath: audioPath,
            annotation: Annotation(text: transcript?.text ?? "", sttEngine: transcript?.engine),
            guardInfo: GuardInfo(status: .pending)
        )
        do {
            try await deps.store.insert(record)
        } catch {
            CCLog.store.error("insert failed: \(String(describing: error), privacy: .public)")
            await removeAttachments(written)
            emit(.failed(.saveFailed(detail: String(describing: error))))
            return
        }
        guard transcript != nil else {
            emit(.failed(.transcriptionFailed(recordID: id)))
            return
        }
        latency.record(.releaseToSaved, milliseconds: max(0, (deps.uptime() - releaseUptime) * 1000))
        let notice: CaptureNotice? = context.screenshotSkipReason == ScreenshotSkipReason.permissionDenied ? .screenRecordingDenied : nil
        emit(.saved(record, notice: notice))
        onRecordSaved(id)
    }

    private func removeAttachments(_ paths: [String]) async {
        for p in paths {
            if let url = try? await deps.store.attachmentURL(for: p) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func removeTemporaryAudio(_ audio: RecordedAudio) {
        if let url = audio.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - 補助

    private func isCurrent(_ s: Session) -> Bool {
        switch state {
        case let .starting(x), let .recording(x): return x === s
        case .idle, .stopping: return false
        }
    }

    private func syntheticRelease(for s: Session) -> HotKeyEvent {
        let now = deps.uptime()
        return HotKeyEvent(kind: .released, uptime: now, date: Date(), pressDuration: max(0, now - s.pressUptime))
    }

    private func emit(_ e: CaptureEvent) {
        continuation.yield(e)
    }

    private func spawn(_ body: @escaping @MainActor () async -> Void) {
        let id = UUID()
        inFlight[id] = Task { @MainActor in
            await body()
            self.inFlight[id] = nil
        }
    }

    /// 走っている押下・解放・保存の処理がすべて終わるまで待つ（テスト用）。
    func waitUntilSettled() async {
        while let t = inFlight.values.first {
            await t.value
        }
    }
}

extension Date {
    /// ミリ秒に丸める（DB はミリ秒精度。往復後の `==` を保つため。計画書 §6 の持ち越し事項）。
    var ccRoundedToMilliseconds: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
