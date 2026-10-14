import CCCore
import CoreGraphics
import Foundation
import OSLog

/// 保存後に非同期で走るトリアージのキュー（PRD §4・§8.1、F-09 / F-10 / F-11）。
///
/// - 1 件ずつ**直列**に、guard → intent → index の順で処理する。各ステップは独立に失敗してよい
///   （1 つの失敗が他のステップを止めない）。失敗したステップは次回の `resumePending()` で拾われる状態のまま残す。
/// - モデル（d1・埋め込み）が未準備のエラー（`ModelReadinessReporting.isModelNotReady`）は失敗にせず
///   `.skipped(.notReady)` にする。何も書かないので、モデルが揃った後の `resumePending()` で拾われる。
/// - 書き込みは `modify`（トランザクション内の read-modify-write）で最新を読み直し、**該当フィールドだけ**を変える。
///   - guard: `guardInfo.status == .pending` で、スクショのパスが処理開始時と同じときだけ書く（ユーザーが clear / masked
///     にした後は上書きしない）。
///   - intent: `triage.model == TriageMarkers.manualModel`（ユーザーが手で変えた）なら書かない。推定中に注釈が編集されたら
///     書かない（編集側が `reprocess` を投げる）。
///   - index: 推定中に注釈・タイトルが変わったら書かない。guard が needs_review でも入れる（ローカルの検索にしか使わない）。
/// - 意図モデル（d1）は最後の使用から `Configuration.classifierIdleTimeout`（既定 10 分）で `unload()` する。処理中は解放しない。
/// - `pause()` / `resume()`: キャプチャ（録音開始〜保存完了）の間、**次のステップを始めない**（進行中のステップは中断しない）。
///   文字起こし（Whisper、ANE）とガード（Vision OCR）・索引（埋め込み、ANE）が重なると STT が約 2 倍になるため
///   （docs/e2e/report.md §7）。止めたまま再開されなくても `Configuration.maxPauseDuration` で自動的に再開する。
/// - 同じ記録を重ねて処理しない: 待ち行列に同じ id があればステップを合わせて 1 件にする。処理中の id に対しては
///   - `enqueue` / `resumePending`（「済んでいなければやる」）は、処理中のジョブが持つステップを積まない。そのステップが
///     失敗・未準備（`.failed` / `.skipped(.notReady)`）で終わったときだけ、処理の後に 1 回積み直す
///     （モデルの準備完了で呼ばれた `resumePending` を、ちょうど処理中だった未準備のステップが取りこぼさないように）。
///   - `reprocess` / `reindexAndWait`（「今の結果は古いのでやり直す」）は、処理の後に 1 回走る（何度呼んでも待ち行列で 1 件にまとまる）。
///   ⚠️ 残る窓: `resumePending` がストアを読んだ直後に同じ記録の処理が始まり、積む前に終わり切ると重ねて積む
///   （ストアの読み取りは数 ms、1 件の処理は秒単位なので実害は小さい）。
/// - ⚠️ OCR 結果・検出文字列・注釈本文はログにもイベントにも出さない。
public actor TriageQueue {
    public struct Configuration: Sendable {
        /// d1 を解放するまでの無使用時間（PRD §8.1: 10 分）。テストでは短くする。
        public var classifierIdleTimeout: Duration
        /// d1 に渡す注釈の最大文字数。
        public var maxAnnotationCharacters: Int
        /// `pause()` のまま `resume()` が来なかったときに自動で再開するまでの時間（呼び出し側の取りこぼしの保険）。
        /// 既定 180 秒 = 録音の上限（AppCoordinator の 120 秒）+ 文字起こし・保存の余裕。
        public var maxPauseDuration: Duration

        public init(
            classifierIdleTimeout: Duration = .seconds(600),
            maxAnnotationCharacters: Int = AnnotationPreprocessor.maxCharacters,
            maxPauseDuration: Duration = .seconds(180)
        ) {
            self.classifierIdleTimeout = classifierIdleTimeout
            self.maxAnnotationCharacters = maxAnnotationCharacters
            self.maxPauseDuration = maxPauseDuration
        }
    }

    private struct Job {
        var id: String
        var steps: Set<TriageStep>
    }

    private let store: any TriageRecordStore
    private let classifier: any IntentClassifying & ModelUnloadable
    private let scanner: any SecretScanning
    private let embedder: any Embedder
    private let screenshots: any ScreenshotLoading
    public nonisolated let configuration: Configuration

    private var queue: [Job] = []
    /// 処理中のジョブ（`drain` が待ち行列から取り出して `process` している間だけ）。
    private var inFlight: Job?
    /// 処理中のジョブのステップのうち、`enqueue` / `resumePending` が重ねて頼んだもの（処理中は積まずにここへ預ける）。
    private var absorbedSteps: Set<TriageStep> = []
    /// 処理中のジョブの各ステップの結果（預かったステップを積み直すかの判定用）。
    private var inFlightOutcomes: [TriageStep: TriageStepOutcome] = [:]
    private var worker: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscribers: [UUID: AsyncStream<TriageEvent>.Continuation] = [:]
    /// 分類器を使うたびに増える。解放タイマは自分の世代が最新のときだけ解放する。
    private var classifierGeneration = 0
    /// 前回の解放以降に分類器を使ったか（使っていなければタイマを張らない）。
    private var classifierUsedSinceUnload = false
    private var unloadTimer: Task<Void, Never>?
    /// `reindexAndWait` が見張っている記録の、索引ステップの最後の結果。
    private var indexWatches: [UUID: IndexWatch] = [:]
    /// 一時停止中か（`pause()` / `resume()`）。
    private var paused = false
    /// 一時停止が解けるのを待っているワーカー。
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    /// `maxPauseDuration` で自動再開するタイマ。
    private var pauseTimer: Task<Void, Never>?
    /// pause のたびに増える。タイマは自分の世代の一時停止だけを解く（前の pause の遅れたタイマで次の pause を解かない）。
    private var pauseGeneration = 0
    /// 自動再開した回数（取りこぼしの検出用）。
    public private(set) var autoResumeCount = 0

    private struct IndexWatch {
        var ids: Set<String>
        var outcomes: [String: TriageStepOutcome] = [:]
    }

    public init(
        store: any TriageRecordStore,
        classifier: any IntentClassifying & ModelUnloadable,
        scanner: any SecretScanning,
        embedder: any Embedder,
        screenshots: any ScreenshotLoading,
        configuration: Configuration = Configuration()
    ) {
        self.store = store
        self.classifier = classifier
        self.scanner = scanner
        self.embedder = embedder
        self.screenshots = screenshots
        self.configuration = configuration
    }

    // MARK: - 公開 API

    /// 新しく保存したレコードを全ステップで処理する（保存直後に呼ぶ）。
    /// 処理中の同じ記録には重ねない（処理中のステップが失敗・未準備で終わったときだけ、処理の後に積み直す）。
    public func enqueue(id: String) {
        scheduleIfNeeded(Job(id: id, steps: Set(TriageStep.allCases)))
    }

    /// 指定ステップだけ再実行する。注釈を編集したときは既定の `[.intent, .index]`。
    /// 手で変えた意図（`TriageMarkers.manualModel`）は再実行しても上書きしない。
    /// 同じ記録が処理中なら、その処理の後に 1 回走る（待ち行列の同じ記録とはステップを合わせて 1 件にする）。
    public func reprocess(id: String, steps: Set<TriageStep> = [.intent, .index]) {
        guard !steps.isEmpty else { return }
        schedule(Job(id: id, steps: steps))
    }

    /// 起動時の再開。未完了のステップがあるレコードを**古い順**に投入し、投入した件数を返す
    /// （処理中の記録のうち、処理中のステップで足りるものは積まず、数えない）。
    /// - guard が pending → guard
    /// - triage が nil で注釈（前処理後）が空でない → intent
    /// - 埋め込みが無い → index
    @discardableResult
    public func resumePending() async throws -> Int {
        let total = try await store.count(InboxFilter(statuses: []))
        guard total > 0 else { return 0 }
        let records = try await store.list(InboxFilter(statuses: [], limit: total))
        let unindexed = try await store.idsWithoutEmbedding(dimension: embedder.dimension)
        var n = 0
        // list は新しい順なので逆にする。
        for record in records.reversed() {
            var steps: Set<TriageStep> = []
            if record.guardInfo.status == .pending { steps.insert(.guardScan) }
            if record.triage == nil,
               !AnnotationPreprocessor.prepare(record.annotation.text, maxCharacters: configuration.maxAnnotationCharacters).isEmpty {
                steps.insert(.intent)
            }
            if unindexed.contains(record.id) { steps.insert(.index) }
            guard !steps.isEmpty else { continue }
            if scheduleIfNeeded(Job(id: record.id, steps: steps)) { n += 1 }
        }
        return n
    }

    /// 索引だけを作り直し、キューが空になるまで待って、**索引ステップが成功しなかった記録**を返す（索引の作り直しの完了判定用）。
    ///
    /// 記録ごとに最後に出た索引ステップの結果で判定する:
    /// - 成功扱い: `.succeeded`、`.skipped(.recordMissing)`（消えた記録は対象外）
    /// - それ以外（失敗・未準備・処理中に注釈が編集されて古いベクトルを捨てた後、やり直しが走らなかった等）は `failedIDs`
    /// 注釈の編集で捨てたもの（`.annotationChanged`）は、編集側の `reprocess` が同じ待ちの間に成功すれば成功になる。
    public func reindexAndWait(ids: [String]) async -> TriageReindexReport {
        guard !ids.isEmpty else { return TriageReindexReport(requested: 0, failedIDs: []) }
        let key = UUID()
        indexWatches[key] = IndexWatch(ids: Set(ids))
        for id in ids { schedule(Job(id: id, steps: [.index])) }
        await waitUntilIdle()
        let watch = indexWatches.removeValue(forKey: key) ?? IndexWatch(ids: Set(ids))
        var seen = Set<String>()
        let failed = ids.filter { id in
            guard seen.insert(id).inserted else { return false }
            switch watch.outcomes[id] {
            case .succeeded?, .skipped(.recordMissing)?: return false
            default: return true
            }
        }
        return TriageReindexReport(requested: seen.count, failedIDs: failed)
    }

    /// 進捗のストリーム。呼ぶたびに新しい購読（複数購読できる）。購読前のイベントは届かない。
    public func events() -> AsyncStream<TriageEvent> {
        let (stream, continuation) = AsyncStream<TriageEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let key = UUID()
        subscribers[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(key) }
        }
        return stream
    }

    /// キューが空で処理中のものも無くなるまで待つ（テスト・終了処理用）。
    public func waitUntilIdle() async {
        if worker == nil && queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// 処理中または待ちがあるか。
    public var isBusy: Bool { worker != nil || !queue.isEmpty }

    /// 次のステップを始めないようにする（キャプチャの開始時に呼ぶ）。進行中のステップはそのまま終わらせる。
    /// 投入（`enqueue` 等）は受け付ける。すでに止まっていれば何もしない（入れ子は数えない。数えるのは呼び出し側）。
    /// ⚠️ 止まっている間は `waitUntilIdle()` / `reindexAndWait` も再開まで返らない。
    public func pause() {
        guard !paused else { return }
        paused = true
        pauseGeneration += 1
        let generation = pauseGeneration
        let limit = configuration.maxPauseDuration
        pauseTimer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            await self?.autoResume(generation: generation)
        }
    }

    /// 一時停止を解き、待っていたステップを始める。止まっていなければ何もしない。
    public func resume() {
        guard paused else { return }
        paused = false
        pauseTimer?.cancel()
        pauseTimer = nil
        let waiters = pauseWaiters
        pauseWaiters = []
        for w in waiters { w.resume() }
    }

    /// 一時停止中か。
    public var isPaused: Bool { paused }

    private func autoResume(generation: Int) {
        guard paused, generation == pauseGeneration else { return }
        autoResumeCount += 1
        Logger(subsystem: "dev.ysogabe.ContextCapture", category: "triage").notice("triage auto-resumed: capture pause exceeded its maximum duration")
        resume()
    }

    /// 一時停止中なら解けるまで待つ（ステップの境目で呼ぶ）。
    private func waitWhilePaused() async {
        while paused {
            await withCheckedContinuation {
                pauseWaiters.append($0)
                broadcast(.suspendedForCapture)
            }
        }
    }

    /// 待っている件数（処理中のものは含まない）。
    public var pendingCount: Int { queue.count }

    // MARK: - キュー

    /// 「済んでいなければやる」依頼（`enqueue` / `resumePending`）。処理中の同じ記録が持つステップは積まずに預け、
    /// 処理の後に結果を見て積み直すか決める（`finishInFlight`）。何か積んだ（または待ち行列へ合わせた）なら true。
    @discardableResult
    private func scheduleIfNeeded(_ job: Job) -> Bool {
        var job = job
        if let current = inFlight, current.id == job.id {
            let covered = job.steps.intersection(current.steps)
            absorbedSteps.formUnion(covered)
            job.steps.subtract(covered)
        }
        guard !job.steps.isEmpty else { return false }
        schedule(job)
        return true
    }

    /// 処理中のジョブを終える。預かったステップのうち、失敗・未準備で終わったものだけ積み直す。
    private func finishInFlight() {
        guard let current = inFlight else { return }
        let retry = absorbedSteps.filter { step in
            switch inFlightOutcomes[step] {
            case .failed?, .skipped(.notReady)?: return true
            default: return false
            }
        }
        inFlight = nil
        absorbedSteps = []
        inFlightOutcomes = [:]
        if !retry.isEmpty { schedule(Job(id: current.id, steps: retry)) }
    }

    private func schedule(_ job: Job) {
        // まだ始まっていない同じ id のジョブがあればステップを合わせる（同じレコードを二重に処理しない）。
        if let i = queue.firstIndex(where: { $0.id == job.id }) {
            queue[i].steps.formUnion(job.steps)
        } else {
            queue.append(job)
        }
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        // 処理を始めたら解放タイマは止める（キュー処理中は解放しない）。
        unloadTimer?.cancel()
        unloadTimer = nil
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            await waitWhilePaused()
            let job = queue.removeFirst()
            inFlight = job
            await process(job)
            finishInFlight()
        }
        worker = nil
        broadcast(.idle)
        scheduleUnloadIfNeeded()
        let waiters = idleWaiters
        idleWaiters = []
        for w in waiters { w.resume() }
    }

    private func process(_ job: Job) async {
        let record: ContextRecord
        let input: EmbeddingInput?
        do {
            let fetched: ContextRecord?
            if let versioned = store as? any VersionedEmbeddingStoring {
                input = try await versioned.embeddingInput(id: job.id)
                fetched = input?.record
            } else { input = nil; fetched = try await store.get(id: job.id) }
            guard let r = fetched else {
                for step in job.steps.sorted() {
                    finishStep(id: job.id, step: step, outcome: .skipped(.recordMissing))
                }
                broadcast(.recordFinished(id: job.id))
                return
            }
            record = r
        } catch {
            for step in job.steps.sorted() {
                finishStep(id: job.id, step: step, outcome: .failed(Self.describe(error)))
            }
            broadcast(.recordFinished(id: job.id))
            return
        }

        // スクショは guard と index で共有する。読めなければ guard は失敗（pending のまま）、index はテキストのみで続ける
        // （検索できないより、画像なしでも検索できるほうがよい）。
        var image: CGImage?
        var imageError: Error?
        if let path = record.screenshotPath,
           job.steps.contains(.guardScan) || job.steps.contains(.index) {
            do { image = try await screenshots.loadScreenshot(relativePath: path) } catch { imageError = error }
        }

        if job.steps.contains(.guardScan) {
            await waitWhilePaused()
            let outcome = await runGuard(record: record, image: image, imageError: imageError)
            finishStep(id: job.id, step: .guardScan, outcome: outcome)
        }
        if job.steps.contains(.intent) {
            await waitWhilePaused()
            let outcome = await runIntent(record: record)
            finishStep(id: job.id, step: .intent, outcome: outcome)
        }
        if job.steps.contains(.index) {
            await waitWhilePaused()
            let outcome = await runIndex(record: record, image: image, input: input)
            finishStep(id: job.id, step: .index, outcome: outcome)
        }
        broadcast(.recordFinished(id: job.id))
    }

    // MARK: - ステップ

    private func runGuard(record: ContextRecord, image: CGImage?, imageError: Error?) async -> TriageStepOutcome {
        guard record.guardInfo.status == .pending else { return .skipped(.alreadyReviewed) }
        let newInfo: GuardInfo
        if record.screenshotPath == nil {
            newInfo = GuardInfo(status: .clear, findings: [])
        } else {
            guard let image else { return .failed(imageError.map(Self.describe) ?? "screenshot unavailable") }
            do {
                let findings = try await scanner.scan(image: image)
                newInfo = GuardInfo(status: findings.isEmpty ? .clear : .needsReview, findings: findings)
            } catch {
                return .failed(Self.describe(error))
            }
        }
        let expectedPath = record.screenshotPath
        return await write(record.id) { r in
            guard r.guardInfo.status == .pending else { return .skipped(.alreadyReviewed) }
            // 処理中にスクショが差し替わった・消えたなら、この結果は別の画像のもの。pending のまま次回に回す。
            guard r.screenshotPath == expectedPath else { return .skipped(.screenshotChanged) }
            r.guardInfo = newInfo
            return .succeeded
        }
    }

    private func runIntent(record: ContextRecord) async -> TriageStepOutcome {
        if record.triage?.isManual == true { return .skipped(.manuallyEdited) }
        let originalText = record.annotation.text
        let text = AnnotationPreprocessor.prepare(originalText, maxCharacters: configuration.maxAnnotationCharacters)
        guard !text.isEmpty else {
            // 注釈が空になった（編集で消された）なら、前の自動推定は意味を失うので消す。
            if record.triage != nil {
                _ = await write(record.id) { r in
                    guard r.annotation.text == originalText, r.triage?.isManual == false else { return .skipped(.annotationChanged) }
                    r.triage = nil
                    return .succeeded
                }
            }
            return .skipped(.emptyAnnotation)
        }
        let result: TriageResult
        do {
            classifierGeneration += 1
            classifierUsedSinceUnload = true
            result = try await classifier.classify(text: text)
        } catch {
            return Self.outcome(for: error)
        }
        return await write(record.id) { r in
            if r.triage?.isManual == true { return .skipped(.manuallyEdited) }
            guard r.annotation.text == originalText else { return .skipped(.annotationChanged) }
            r.triage = result
            return .succeeded
        }
    }

    private func runIndex(record: ContextRecord, image: CGImage?, input: EmbeddingInput?) async -> TriageStepOutcome {
        let text = AnnotationPreprocessor.stripSpecialTokens(record.annotation.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = record.window?.title
        let vector: [Float]
        var signed: SignedEmbedding?
        do {
            if let reporting = embedder as? any SignatureReportingEmbedder {
                let result = try await reporting.embedDocumentWithSignature(text: text, title: title, image: image)
                signed = result; vector = result.vector
            } else { vector = try await embedder.embedDocument(text: text, title: title, image: image) }
        } catch {
            return Self.outcome(for: error)
        }
        do {
            if let input, let versioned = store as? any VersionedEmbeddingStoring {
                let result = signed ?? SignedEmbedding(vector: vector, compatibilityKey: "legacy-unsigned")
                return try await versioned.commitEmbedding(result, input: input) ? .succeeded : .skipped(.annotationChanged)
            }
            // フェイク等、versioned store でない場合の互換経路。
            guard let latest = try await store.get(id: record.id) else { return .skipped(.recordMissing) }
            guard latest.annotation.text == record.annotation.text, latest.window?.title == title else {
                return .skipped(.annotationChanged)
            }
            try await store.setEmbedding(id: record.id, vector: vector)
            return .succeeded
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// `modify` で最新を読み直して書く。transform が skipped を返したら書き込みはしない（transform 内で変更しない）。
    private func write(
        _ id: String,
        _ transform: @escaping @Sendable (inout ContextRecord) -> TriageStepOutcome
    ) async -> TriageStepOutcome {
        let box = OutcomeBox()
        do {
            try await store.modify(id: id) { r in
                let outcome = transform(&r)
                box.set(outcome)
                if outcome != .succeeded { throw SkipWrite() }
            }
            return box.get() ?? .succeeded
        } catch is SkipWrite {
            return box.get() ?? .skipped(.annotationChanged)
        } catch {
            if box.get() == nil, (try? await store.get(id: id)) == nil { return .skipped(.recordMissing) }
            return .failed(Self.describe(error))
        }
    }

    // MARK: - d1 の解放

    private func scheduleUnloadIfNeeded() {
        guard classifierUsedSinceUnload else { return }
        unloadTimer?.cancel()
        let generation = classifierGeneration
        let delay = configuration.classifierIdleTimeout
        unloadTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle(generation: generation)
        }
    }

    private func unloadIfIdle(generation: Int) async {
        guard generation == classifierGeneration, worker == nil, queue.isEmpty else { return }
        classifierUsedSinceUnload = false
        unloadTimer = nil
        await classifier.unload()
        broadcast(.classifierUnloaded)
    }

    // MARK: - イベント

    /// ステップの終わりを知らせ、`reindexAndWait` の見張りに索引の結果を残す。
    private func finishStep(id: String, step: TriageStep, outcome: TriageStepOutcome) {
        if inFlight?.id == id { inFlightOutcomes[step] = outcome }
        if step == .index {
            for key in indexWatches.keys where indexWatches[key]!.ids.contains(id) {
                indexWatches[key]!.outcomes[id] = outcome
            }
        }
        broadcast(.stepFinished(id: id, step: step, outcome: outcome))
    }

    private func broadcast(_ event: TriageEvent) {
        for c in subscribers.values { c.yield(event) }
    }

    private func unsubscribe(_ key: UUID) {
        subscribers[key] = nil
    }

    /// モデルの呼び出しが投げたエラーの結果。未準備（`ModelReadinessReporting.isModelNotReady`）は失敗にせず後回しにする。
    static func outcome(for error: Error) -> TriageStepOutcome {
        if (error as? any ModelReadinessReporting)?.isModelNotReady == true { return .skipped(.notReady) }
        return .failed(describe(error))
    }

    /// 失敗の説明。エラーの本文に秘密や注釈が混ざる可能性を避け、型名とドメイン・コードだけにする。
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(type(of: error)) (\(ns.domain)#\(ns.code))"
    }
}

/// `modify` のクロージャ（@Sendable）から結果を持ち出すための箱。
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TriageStepOutcome?
    func set(_ v: TriageStepOutcome) { lock.withLock { value = v } }
    func get() -> TriageStepOutcome? { lock.withLock { value } }
}

private struct SkipWrite: Error {}
