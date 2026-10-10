import CCCore
import Foundation

/// UI が使う依存の組み立て点（ここ 1 か所）。
///
/// - `--fake` 起動引数か環境変数 `CC_UI_FAKE=1` → `fake()`（メモリ上のストア・サンプル 10 件・偽の録音イベント）
/// - それ以外 → `live()`。**wiring 担当が本物を差し込む場所**（`// WIRING:` の行）
@MainActor
struct AppEnvironment {
    var store: any RecordStore
    var search: any SearchServing
    var capture: any CaptureControlling
    var guardReview: any GuardReviewing
    var settings: any SettingsStore
    var permissions: any PermissionsProviding
    var models: any ModelPreparationProviding
    /// フェイクで動いているか（メニューに「フェイク操作」を出す）。
    var isFake: Bool
    /// フェイク時だけ。メニューから偽の録音・失敗を流す。
    var fakeCapture: FakeCaptureController?
    /// 「今日」「昨日」の判定に使う時計（スナップショットで固定するため）。
    var now: @Sendable () -> Date = { Date() }

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

    /// 本番の組み立て。Wave 2 UI 時点では本物が無いので、空のストアと何も流さないキャプチャで起動する。
    static func live() -> AppEnvironment {
        let store = FakeRecordStore()                              // WIRING: SQLiteRecordStore（1 プロセス 1 インスタンス）
        return AppEnvironment(
            store: store,
            search: FakeSearchService(store: store),               // WIRING: Embedder.embedQuery → RecordStore.search
            capture: UnwiredCaptureController(),                   // WIRING: AppCoordinator（ホットキー → 撮影+録音 → STT → 保存）
            guardReview: FakeGuardReviewer(store: store),          // WIRING: CCGuard のマスク生成 + store.update
            settings: UserDefaultsSettingsStore(),                 // 本物（このまま使う）
            permissions: SystemPermissions(),                      // 本物（このまま使う。オートメーションだけ状態を取れない）
            models: UnwiredModelPreparation(),                     // WIRING: cc-models prepare 相当（CCModels）+ 各モデルの prepare()
            isFake: false,
            fakeCapture: nil
        )
    }
}

/// 本物が差し込まれるまでの、何も流さないキャプチャ。
struct UnwiredCaptureController: CaptureControlling {
    func events() -> AsyncStream<CaptureEvent> { AsyncStream { _ in } }
    func undo(recordID: String) async throws {}
    func retryTranscription(recordID: String) async {}
}

/// 本物が差し込まれるまでのモデル準備。準備済み扱いにする（オンボーディングは進捗を出さずに通る）。
struct UnwiredModelPreparation: ModelPreparationProviding {
    func isPrepared() async -> Bool { true }
    func prepare() -> AsyncThrowingStream<ModelPreparationProgress, Error> {
        AsyncThrowingStream { c in
            c.yield(ModelPreparationProgress(phase: .finished, fractionCompleted: 1, completedBytes: 0, totalBytes: 0))
            c.finish()
        }
    }
}
