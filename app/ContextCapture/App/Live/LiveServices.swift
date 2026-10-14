import AppKit
import AVFoundation
import CCCapture
import CCCore
import CCEmbedding
import CCGuard
import CCIntent
import CCModels
import CCSTT
import CCStore
import CCTriage
import Foundation
import MLX

/// 本番の部品一式と、起動時・設定変更時の配線（`AppEnvironment.live()` が 1 つだけ作る）。
///
/// - ストア: `SQLiteRecordStore`（**1 プロセス 1 インスタンス**。`CC_DATA_DIR` を尊重）
/// - キャプチャ: `AppCoordinator`（ホットキー → 撮影 + 録音 → STT → 保存 → トースト）
/// - モデル: `ModelPreparationPipeline`（文字起こし → 検索 → 意図。`CC_MODELS_DIR` を尊重）。STT と同じ `WhisperKitTranscriber` を共有する
/// - 保存後: `TriageQueue`（ガード → 意図 → 索引）。d1・埋め込みは揃っていなければそのステップだけ失敗で残り、揃ってから
///   `resumePending()` で拾う（記録は残る）
/// - 検索: `EmbeddingSearchService`（埋め込みの準備中・失敗時は文字の一致へ）。索引の整合は `SearchIndexMaintainer`
@MainActor
final class LiveServices {
    let paths: CCPaths
    let store: SQLiteRecordStore
    let settings: any SettingsStore
    let capturer: FrontmostContextCapturer
    let recorder: PushToTalkRecorder
    let transcriber: WhisperKitTranscriber
    let coordinator: AppCoordinator
    let whisper: WhisperModelSlot
    let models: ModelPreparationPipeline
    let classifier: D1IntentClassifier
    let embedder: SwitchableEmbedder
    let triageQueue: TriageQueue
    let triage: TriageWiring
    let searchIndex: SearchIndexMaintainer
    let search: EmbeddingSearchService
    let guardReviewer: LiveGuardReviewer
    /// デバッグメニューに出す各モデルの読み込み状態とメモリ。
    let debugStatus = ModelDebugStatus()
    let hotKeys = HotKeyController()
    let latency = CaptureLatencyMonitor()
    /// `--debug` 起動（または `CC_DEBUG=1`）。⌥ を押しながらメニューを開いたときもデバッグメニューを出す（AppModel 側）。
    let debugLaunch: Bool

    private weak var model: AppModel?
    private var settingsObserver: NSObjectProtocol?
    private var retentionTask: Task<Void, Never>?
    private var started = false
    /// 診断の実行中（二重起動を防ぐ）。
    private(set) var isRunningDiagnostics = false

    init(settings: any SettingsStore,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         arguments: [String] = ProcessInfo.processInfo.arguments) throws {
        paths = CCPaths.resolve(environment: environment)
        self.settings = settings
        store = try SQLiteRecordStore(paths: paths)
        let s = settings.load()
        capturer = FrontmostContextCapturer(configuration: CaptureConfiguration(
            excludedBundleIDs: Set(s.excludedApps.map(\.bundleID)),
            automationConsent: .askOnFirstUse
        ))
        recorder = PushToTalkRecorder()
        transcriber = WhisperKitTranscriber(paths: paths)
        let settingsRef = settings
        let store = store

        // 保存後の処理（ガード → 意図 → 索引）。モデルの場所は `paths` から明示的に渡す（部品の既定は CCPaths.resolve() を読み直す）。
        classifier = D1IntentClassifier(modelDirectory: paths.modelDirectory(.d1))
        embedder = SwitchableEmbedder()
        triageQueue = TriageQueue(store: store, classifier: classifier, scanner: VisionSecretScanner(), embedder: embedder,
                                  screenshots: StoreScreenshotLoader(store: store))
        triage = TriageWiring(queue: triageQueue)

        let embeddingPreparer = EmbeddingModelPreparer(paths: paths)
        let embeddingDirectory = paths.modelDirectory(.embedding)
        let maintainer = SearchIndexMaintainer(
            embedder: embedder, queue: triageQueue, store: store,
            stateURL: SearchIndexState.url(dataRoot: paths.dataRoot)
        ) { imageTokens in
            switch try? embeddingPreparer.verify(level: .size) {
            case .ready?, .unmanifested?:
                return CoreMLEmbedder(configuration: .app(modelDirectory: embeddingDirectory, imageTokens: imageTokens))
            default:
                return nil
            }
        }
        searchIndex = maintainer
        search = EmbeddingSearchService(embedder: embedder, store: store, readiness: { await maintainer.readiness },
                                        degradedFailedIDs: { await maintainer.degradedFailedIDs })
        guardReviewer = LiveGuardReviewer(store: store, modify: { id, transform in try await store.modify(id: id, transform) })

        whisper = WhisperModelSlot(preparer: WhisperModelPreparer(paths: paths), transcriber: transcriber)
        let modelsRoot = paths.modelsRoot
        models = ModelPreparationPipeline(
            slots: [
                whisper,
                EmbeddingModelSlot(preparer: embeddingPreparer),
                D1ModelSlot(preparer: D1ModelPreparer(destination: paths.modelDirectory(.d1))),
            ],
            availableBytes: { ModelPreparationPipeline.availableCapacity(at: modelsRoot) },
            onPrepared: { @MainActor in
                // 揃ったモデルで、後回しにしていたステップを拾う（検索モデルは裏で初回最適化を始める）。
                maintainer.modelsPrepared(imageTokens: settingsRef.load().imageTokenBudget)
            }
        )
        coordinator = AppCoordinator(
            dependencies: CaptureDependencies(
                capturer: capturer,
                recorder: recorder,
                transcriber: transcriber,
                store: store,
                vocabulary: { settingsRef.load().vocabulary }
            ),
            latency: latency
        )
        debugLaunch = arguments.contains("--debug") || environment["CC_DEBUG"] == "1"
        CCLog.store.notice("data: \(self.paths.dataRoot.path, privacy: .public) models: \(self.paths.modelsRoot.path, privacy: .public)")
        CCLog.capture.notice("screenshot format: \(ScreenshotEncoder.chosenFormat?.fileExtension ?? "none", privacy: .public)")
    }

    /// 起動時に 1 回（`AppModel.start()` から）。
    func start(model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model

        let triage = triage
        triage.onRecordsChanged = { [weak model] in model?.recordsDidChange() }
        triage.onClassifierUnloaded = { [weak self] in self?.refreshDebugStatusSoon() }
        coordinator.onRecordSaved = { id in
            CCLog.capture.debug("saved \(id, privacy: .public)")
            triage.recordSaved(id: id)
        }
        // 文字起こしの再試行で注釈が入った → 意図と索引をやり直す（ガードは保存時に回してある）。
        coordinator.onTranscriptRetried = { id in
            CCLog.capture.debug("transcript retried \(id, privacy: .public)")
            triage.annotationEdited(id: id)
        }
        // 録音〜保存の間はトリアージの次のステップを始めない（Whisper とガード・索引が ANE を取り合うと STT が約 2 倍。
        // docs/e2e/report.md §7）。AppCoordinator は取り消し・失敗でも必ず false を送る。
        coordinator.onCaptureActivityChanged = { active in
            triage.captureActivityChanged(active)
        }
        coordinator.onRecordRemoved = { id in
            // キューから外す API は無いが、TriageQueue は処理時に消えた記録を .recordMissing で飛ばす。
            CCLog.capture.debug("removed \(id, privacy: .public)")
        }
        searchIndex.onReadinessChange = { [weak model] r in
            CCLog.models.notice("search readiness: \(String(describing: r), privacy: .public)")
            model?.setSearchReadiness(r)
        }
        model.setSearchReadiness(searchIndex.readiness)

        hotKeys.onEvent = { [weak self] e in self?.coordinator.handle(e) }
        hotKeys.willReset = { [weak self] in self?.coordinator.endActiveRecordingForHotKeyReset() }
        hotKeys.onStatusChange = { [weak model, weak self] status in
            model?.setHotKeyStatus(status, hotkey: self?.hotKeys.combo.display ?? "")
        }
        hotKeys.register(settings.load().hotkey)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsChange.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }

        // マイクが許可済みのときだけ録音の下準備（未許可で触らない。押下時の start() が同じことをする）。
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            let recorder = recorder
            Task.detached(priority: .utility) {
                do { try await recorder.prepare() } catch {
                    CCLog.capture.error("recorder.prepare failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        // 1) トリアージの進捗の購読 → 2) Whisper の読み込み（初回は ANE 特殊化で約 1 分。冪等。オンボーディングの準備も同じ読み込みを待つ）
        // → 3) 埋め込みの準備（ANE の初回特殊化で数分）と、未完了のトリアージの再開。2 と 3 はどちらも ANE を使うので順に。
        let transcriber = transcriber, whisperPresent = whisper.filesPresent(), queue = triageQueue
        let imageTokens = settings.load().imageTokenBudget
        searchIndex.markPreparationPending(imageTokens: imageTokens)
        if !whisperPresent {
            CCLog.models.notice("whisper model not found under \(self.paths.modelsRoot.path, privacy: .public)")
        }
        Task { [weak self] in
            triage.observe(await queue.events())
            if whisperPresent {
                let t0 = Date()
                do {
                    // 読み込み + 温め（合成音で 1 回推論）。温めないと起動後の最初の文字起こしが 5〜8 秒かかる（report §7 問題 3）。
                    // 温めの間に録音されたら、その文字起こしは温めの完了を待ってから普通に処理される（キャプチャは待たせない）。
                    try await transcriber.prepare()
                    let warm = await transcriber.lastWarmUpDuration
                    CCLog.models.notice("""
                        whisper ready in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1), privacy: .public)s \
                        (warm-up \(warm ?? -1, format: .fixed(precision: 2), privacy: .public)s)
                        """)
                } catch {
                    CCLog.models.error("whisper prepare failed: \(String(describing: error), privacy: .public)")
                }
            }
            self?.searchIndex.activate(imageTokens: imageTokens)
        }

        // デバッグメニューのモデルの状態は、メニューを開いたとき（AppDelegate の NSMenu の追跡開始）と d1 の解放時・
        // 「モデルの状態を更新」で読み直す（以前の 5 秒ごとのポーリングはやめた。開いていない間に読む理由が無い）。
        if debugLaunch { refreshDebugStatusSoon() }

        // 保持期間: 起動時と 1 日 1 回。
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.purgeExpired()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    private func applySettings() {
        let s = settings.load()
        capturer.configuration.excludedBundleIDs = Set(s.excludedApps.map(\.bundleID))
        searchIndex.settingsChanged(imageTokens: s.imageTokenBudget)
        if s.hotkey != hotKeys.combo {
            hotKeys.register(s.hotkey)
        } else {
            // オンボーディングでアクセシビリティを許可した直後など。
            hotKeys.retryIfNeeded()
        }
    }

    func purgeExpired(now: Date = Date()) async {
        let s = settings.load()
        do {
            let audio = try await store.purgeExpiredAudio(olderThan: TimeInterval(s.audioRetentionDays) * 24 * 60 * 60, now: now)
            let shots = try await store.purgeExpiredScreenshots(retentionDays: s.screenshotRetentionDays, now: now)
            CCLog.store.notice("retention: audio \(audio) screenshots \(shots)")
            if audio + shots > 0 { model?.recordsDidChange() }
        } catch {
            CCLog.store.error("retention failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - デバッグメニュー（CaptureDiagnostics。どれもダイアログを出さない）

    private var diagnosticsDirectory: URL { paths.dataRoot.appendingPathComponent("diagnostics", isDirectory: true) }

    private func diagnosticsFile(_ name: String, _ ext: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return diagnosticsDirectory.appendingPathComponent("\(name)-\(f.string(from: Date())).\(ext)")
    }

    /// 3 秒待ってから前面コンテキストを 1 回取る（その間に確かめたいアプリを前面にする）。JSON と PNG を書いて JSON の場所を返す。
    func runContextDiagnostics() async -> URL? {
        await runDiagnostics(name: "context") { [self] in
            let png = diagnosticsFile("context", "png")
            return await CaptureDiagnostics.runOnce(CaptureDiagnostics.Options(
                delaySeconds: 3,
                excludedBundleIDs: capturer.configuration.excludedBundleIDs,
                screenshotOutputURL: png
            ))
        }
    }

    /// 3 秒録音して prepare / start の所要時間と音量を記録する。
    func runRecordingDiagnostics() async -> URL? {
        guard coordinator.phase == .idle else { return nil }
        return await runDiagnostics(name: "recording") {
            await CaptureDiagnostics.runRecordingCheck(seconds: 3)
        }
    }

    /// 10 秒間、ホットキーの押下 / 解放を記録する。同じ組み合わせを別に登録するので、その間アプリのホットキーは止める。
    func runHotKeyDiagnostics() async -> URL? {
        guard coordinator.phase == .idle else { return nil }
        let combo = hotKeys.combo
        hotKeys.suspend()
        defer { hotKeys.register(combo) }
        return await runDiagnostics(name: "hotkey") {
            await CaptureDiagnostics.runHotKeyCheck(shortcut: combo.shortcut, seconds: 10)
        }
    }

    private func runDiagnostics(name: String, _ body: () async -> String) async -> URL? {
        guard !isRunningDiagnostics else { return nil }
        isRunningDiagnostics = true
        defer { isRunningDiagnostics = false }
        try? FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let json = await body()
        let url = diagnosticsFile(name, "json")
        do {
            try Data(json.utf8).write(to: url)
            return url
        } catch {
            CCLog.capture.error("diagnostics write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - モデルの状態（デバッグメニュー）

    func refreshDebugStatus() async {
        let whisperLoaded = await transcriber.isLoaded
        let d1Loaded = await classifier.isLoaded
        let embedding = await embedder.loadDescription()
        let busy = await triageQueue.isBusy
        let pending = await triageQueue.pendingCount
        debugStatus.update(
            whisper: whisperLoaded ? "読み込み済み" : "未読み込み",
            d1: d1Loaded ? "読み込み済み" : "未読み込み（解放済み）",
            embedding: "\(embedding)・\(searchIndex.readiness)",
            triage: busy ? "処理中（待ち \(pending) 件）" : "待機",
            mlxActiveBytes: Memory.activeMemory,
            residentBytes: D1IntentClassifier.residentBytes()
        )
    }

    func refreshDebugStatusSoon() {
        Task { await refreshDebugStatus() }
    }

    func revealDataFolder() {
        try? FileManager.default.createDirectory(at: paths.dataRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([paths.dataRoot])
    }
}
