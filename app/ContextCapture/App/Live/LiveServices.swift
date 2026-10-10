import AppKit
import AVFoundation
import CCCapture
import CCCore
import CCModels
import CCSTT
import CCStore
import Foundation

/// 本番の部品一式と、起動時・設定変更時の配線（`AppEnvironment.live()` が 1 つだけ作る）。
///
/// - ストア: `SQLiteRecordStore`（**1 プロセス 1 インスタンス**。`CC_DATA_DIR` を尊重）
/// - キャプチャ: `AppCoordinator`（ホットキー → 撮影 + 録音 → STT → 保存 → トースト）
/// - モデル: `WhisperModelPreparation`（`CC_MODELS_DIR` を尊重）。STT と同じ `WhisperKitTranscriber` を共有する
@MainActor
final class LiveServices {
    let paths: CCPaths
    let store: SQLiteRecordStore
    let settings: any SettingsStore
    let capturer: FrontmostContextCapturer
    let recorder: PushToTalkRecorder
    let transcriber: WhisperKitTranscriber
    let coordinator: AppCoordinator
    let models: WhisperModelPreparation
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
        models = WhisperModelPreparation(preparer: WhisperModelPreparer(paths: paths), transcriber: transcriber)
        let settingsRef = settings
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

        coordinator.onRecordSaved = { id in
            // M2: TriageQueue.enqueue(id: id)（意図・秘密情報ガード・検索索引）をここに差す。
            CCLog.capture.debug("saved \(id, privacy: .public)")
        }
        coordinator.onRecordRemoved = { id in
            // M2: TriageQueue.cancel(id: id) をここに差す。
            CCLog.capture.debug("removed \(id, privacy: .public)")
        }

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

        // モデルが揃っていれば、このプロセスで読み込んでおく（初回は ANE 特殊化で約 1 分。冪等）。
        // オンボーディングの「モデルの準備」も同じ読み込みを待つ。
        if models.filesPresent() {
            let transcriber = transcriber
            Task.detached(priority: .utility) {
                let t0 = Date()
                do {
                    try await transcriber.prepare()
                    CCLog.models.notice("whisper ready in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1), privacy: .public)s")
                } catch {
                    CCLog.models.error("whisper prepare failed: \(String(describing: error), privacy: .public)")
                }
            }
        } else {
            CCLog.models.notice("whisper model not found under \(self.paths.modelsRoot.path, privacy: .public)")
        }

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

    func revealDataFolder() {
        try? FileManager.default.createDirectory(at: paths.dataRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([paths.dataRoot])
    }
}
