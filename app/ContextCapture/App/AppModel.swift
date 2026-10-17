import AppKit
import CCCore
import Observation

/// アプリ全体の状態（メニューバーの件数・録音中か・設定）と、HUD / トースト / ウインドウの持ち主。
/// AppDelegate が 1 つだけ作る。
@Observable
@MainActor
final class AppModel {
    let env: AppEnvironment
    private(set) var settings: AppSettings
    /// 未処理（inbox）の件数。メニューバーに出す。
    private(set) var unprocessedCount = 0
    /// 今日撮った件数（状態を問わない）。
    private(set) var todayCount = 0
    private(set) var isRecording = false
    /// 記録が変わるたびに増える。Inbox はこれを見て読み直す。
    /// wiring: 本物の保存は `.saved` イベントで、それ以外（トリアージ完了・ガード完了など）で記録を書き換えたら `recordsDidChange()` を呼ぶこと。
    private(set) var recordsRevision = 0
    /// ホットキーを登録できないときの説明と対処（メニューバーとオンボーディングに出す）。
    private(set) var hotKeyIssue: HotKeyIssue?
    private(set) var hotKeyStatus: HotKeyStatus = .notRegistered
    /// ⌥ を押しながらメニューを開いたらデバッグメニューを出す（このプロセスの間ずっと）。
    private(set) var debugMenuRevealed = false
    /// 見た目での検索（埋め込み）の状態。メニューバーに「検索の準備中」などを出す。フェイクでは nil（出さない）。
    private(set) var searchReadiness: SearchReadiness?

    @ObservationIgnored let hud = HUDController()
    @ObservationIgnored private(set) lazy var toast = ToastController(model: self)
    @ObservationIgnored private(set) lazy var windows = WindowRouter(model: self)
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    init(env: AppEnvironment) {
        self.env = env
        self.settings = env.settings.load()
    }

    /// イベントの購読を始める（アプリ起動時に 1 回）。
    func start() {
        guard eventsTask == nil else { return }
        let stream = env.capture.events()
        eventsTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsChange.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSettings() }
        }
        Task { await refreshCounts() }
        env.live?.start(model: self)
    }

    /// デバッグメニューを出すか（本番の部品があるときだけ。`--debug` 起動か、⌥ を押しながらメニューを開いたとき）。
    var showsDebugMenu: Bool {
        guard let live = env.live else { return false }
        return live.debugLaunch || debugMenuRevealed
    }

    func setSearchReadiness(_ r: SearchReadiness) {
        searchReadiness = r
    }

    func revealDebugMenu() {
        debugMenuRevealed = true
    }

    func setHotKeyStatus(_ status: HotKeyStatus, hotkey: String) {
        hotKeyStatus = status
        hotKeyIssue = HotKeyIssue.from(status, hotkey: hotkey)
    }

    func reloadSettings() {
        settings = env.settings.load()
    }

    func updateSettings(_ s: AppSettings) {
        settings = s
        env.settings.save(s)
    }

    func recordsDidChange() {
        recordsRevision += 1
        Task { await refreshCounts() }
    }

    func refreshCounts() async {
        let now = env.now()
        let startOfDay = Calendar.current.startOfDay(for: now)
        unprocessedCount = (try? await env.store.count(.inbox)) ?? unprocessedCount
        todayCount = (try? await env.store.count(InboxFilter(statuses: [], since: startOfDay))) ?? todayCount
    }

    func handle(_ event: CaptureEvent) {
        switch event {
        case let .recordingStarted(levels):
            isRecording = true
            hud.show(levels: levels)
        case .recordingEnded, .recordingDiscarded:
            isRecording = false
            hud.hide()
        case let .saved(record, notice):
            // 前の記録の保存が、次の録音中に終わることがある（文字起こし中でも次の押下を受ける）。HUD は録音側に任せる。
            if !isRecording { hud.hide() }
            toast.show(CaptureMessages.saved(record, notice: notice))
            recordsDidChange()
        case let .failed(failure):
            if !isRecording { hud.hide() }
            toast.show(CaptureMessages.failure(failure, hotkey: settings.hotkey.display))
            if case .transcriptionFailed = failure { recordsDidChange() }
        }
    }

    /// トーストのボタン。
    func perform(_ action: ToastContent.Action) {
        switch action {
        case let .undo(id):
            Task {
                do {
                    try await env.capture.undo(recordID: id)
                    toast.show(CaptureMessages.undone())
                } catch {
                    toast.show(ToastContent(kind: .error, title: "取り消せませんでした", body: "Inbox から削除してください。"))
                }
                recordsDidChange()
            }
        case let .retryTranscription(id):
            toast.hide()
            Task { await env.capture.retryTranscription(recordID: id) }
        case let .openSystemSettings(kind):
            Task {
                // マイクが「未確認」ならシステム設定に行の無い（または署名の変わったアプリの古い許可が ON に見えるだけの）
                // 状態なので、オンボーディングと同じくまずシステムのダイアログを出す。画面収録は未確認と拒否を区別できないので設定へ。
                if kind == .microphone, await env.permissions.state(of: kind) == .notDetermined {
                    await env.permissions.request(kind)
                } else {
                    await env.permissions.openSystemSettings(for: kind)
                }
            }
        }
    }
}
