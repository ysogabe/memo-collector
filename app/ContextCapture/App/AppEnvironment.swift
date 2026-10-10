import AppKit
import CCCore
import Foundation

/// UI が使う依存の組み立て点（ここ 1 か所）。
///
/// - `--fake` 起動引数か環境変数 `CC_UI_FAKE=1` → `fake()`（メモリ上のストア・サンプル 10 件・偽の録音イベント）
/// - それ以外 → `live()`（本物。部品の組み立ては `LiveServices`）
@MainActor
struct AppEnvironment {
    var store: any RecordStore
    var search: any SearchServing
    var capture: any CaptureControlling
    var guardReview: any GuardReviewing
    var settings: any SettingsStore
    var permissions: any PermissionsProviding
    var models: any ModelPreparationProviding
    /// 保存後の処理（注釈の編集で意図・索引をやり直す）。フェイクでは何もしない。
    var triage: any TriageQueuing = NoopTriageQueue()
    /// フェイクで動いているか（メニューに「フェイク操作」を出す）。
    var isFake: Bool
    /// フェイク時だけ。メニューから偽の録音・失敗を流す。
    var fakeCapture: FakeCaptureController?
    /// 「今日」「昨日」の判定に使う時計（スナップショットで固定するため）。
    var now: @Sendable () -> Date = { Date() }
    /// 本番の部品と起動時の配線（ホットキー・保持期間・診断）。フェイクでは nil。
    var live: LiveServices?

    static func shouldUseFake(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("--fake") || environment["CC_UI_FAKE"] == "1"
    }

    static func resolve() -> AppEnvironment {
        shouldUseFake() ? fake() : live()
    }

    /// フェイク一式。`now` を渡すとサンプルの時刻もそれに合わせる。
    static func fake(now: Date? = nil, seed: Bool = true) -> AppEnvironment {
        let clock = now ?? Date()
        let store = FakeRecordStore()
        if seed { store.seedSync(FakeData.records(now: clock, imageDirectory: store.root)) }
        let capture = FakeCaptureController(store: store)
        let settingsDefaults = UserDefaults(suiteName: "ContextCapture.fake") ?? .standard
        var env = AppEnvironment(
            store: store,
            search: FakeSearchService(store: store),
            capture: capture,
            guardReview: FakeGuardReviewer(store: store),
            settings: UserDefaultsSettingsStore(defaults: settingsDefaults),
            permissions: FakePermissions(),
            models: FakeModelPreparation(),
            isFake: true,
            fakeCapture: capture
        )
        if let now { env.now = { now } }
        return env
    }

    /// 本番の組み立て（撮影 + 録音 → STT → 保存 → トリアージ（ガード・意図・索引）、埋め込み検索、ガードの確認）。
    static func live() -> AppEnvironment {
        let settings = UserDefaultsSettingsStore()
        let services: LiveServices
        do {
            services = try LiveServices(settings: settings)
        } catch {
            // SQLite を開けない（ディスク・権限・壊れた DB）。黙ってメモリに保存すると記録が消えるので、知らせて終える。
            let paths = CCPaths.resolve()
            CCLog.store.fault("store open failed at \(paths.dataRoot.path, privacy: .public): \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "記録の保存先を開けませんでした"
            alert.informativeText = "\(paths.dataRoot.path)\n\(error.localizedDescription)"
            alert.runModal()
            exit(1)
        }
        let store = services.store
        var env = AppEnvironment(
            store: store,
            search: services.search,
            capture: services.coordinator,
            guardReview: services.guardReviewer,
            settings: settings,
            permissions: SystemPermissions(),
            models: services.models,
            isFake: false,
            fakeCapture: nil
        )
        env.triage = services.triageQueue
        env.live = services
        return env
    }
}
