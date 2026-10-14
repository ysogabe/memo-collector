import AppKit
import ApplicationServices
import CCCapture
import Foundation

/// ホットキーの登録状態（メニューバー・オンボーディングに出す）。
enum HotKeyStatus: Equatable, Sendable {
    case notRegistered
    case active(GlobalPushToTalkHotKey.Backend)
    /// 他アプリが同じ組み合わせを使っている。
    case alreadyInUse
    /// Carbon が拒否し、アクセシビリティ権限が無いので CGEventTap にも切り替えられない。
    case needsAccessibility(carbonStatus: Int32)
    /// その他の失敗（アクセシビリティはあるのに CGEventTap も作れなかった等）。
    case failed(String)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// デバッグメニュー用の短い説明。
    var debugDescription: String {
        switch self {
        case let .active(b): return b == .carbon ? "Carbon" : "CGEventTap"
        case .notRegistered: return "未登録"
        case .alreadyInUse: return "使用中（他アプリ）"
        case let .needsAccessibility(s): return "失敗（Carbon \(s)、アクセシビリティなし）"
        case let .failed(m): return "失敗（\(m)）"
        }
    }
}

/// 登録できないときにユーザーへ出す 1 行と、対処のボタン。
struct HotKeyIssue: Equatable, Sendable {
    var message: String
    /// 「システム設定を開く」で開く権限（nil ならボタンなし）。
    var settingsKind: PermissionKind?

    static func from(_ status: HotKeyStatus, hotkey: String) -> HotKeyIssue? {
        switch status {
        case .active, .notRegistered:
            return nil
        case .alreadyInUse:
            return HotKeyIssue(message: "ほかのアプリが \(hotkey) を使っています。設定でキーを変えてください。", settingsKind: nil)
        case .needsAccessibility:
            return HotKeyIssue(message: "\(hotkey) を登録できませんでした。アクセシビリティを許可すると使えます。", settingsKind: .accessibility)
        case .failed:
            return HotKeyIssue(message: "\(hotkey) を登録できませんでした。設定で別のキーを試してください。", settingsKind: nil)
        }
    }
}

extension HotkeyCombo {
    /// CCCapture のショートカット表現へ。
    var shortcut: HotKeyShortcut {
        var m: HotKeyShortcut.Modifiers = []
        let f = modifierFlags
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.shift) { m.insert(.shift) }
        return HotKeyShortcut(keyCode: UInt32(keyCode), modifiers: m)
    }
}

@MainActor
protocol HotKeyDriving: AnyObject {
    var onEvent: ((HotKeyEvent) -> Void)? { get set }
    var lastCarbonStatus: Int32? { get }
    func stop()
    func setShortcut(_ shortcut: HotKeyShortcut) throws
    func start(allowEventTapFallback: Bool, preferEventTap: Bool) throws -> GlobalPushToTalkHotKey.Backend
}

extension GlobalPushToTalkHotKey: HotKeyDriving {}

/// `GlobalPushToTalkHotKey` の持ち主。登録・登録し直し・失敗時の再試行を受け持つ。
///
/// - Carbon（権限不要）→ 失敗したらアクセシビリティ権限があれば CGEventTap（CCCapture の既定動作）。
/// - アクセシビリティが無くて登録できないときは、2 秒ごとに `AXIsProcessTrusted()` だけを見て（ダイアログは出さない）、
///   許可されたら登録し直す。
@MainActor
final class HotKeyController {
    private let hotKey: any HotKeyDriving
    private(set) var status: HotKeyStatus = .notRegistered
    private(set) var combo: HotkeyCombo = .default
    private var trustPoll: Timer?
    /// 押下 / 解放（メインスレッド）。
    var onEvent: (HotKeyEvent) -> Void = { _ in }
    /// 登録し直す直前（押下中なら解放として扱わせる）。
    var willReset: () -> Void = {}
    /// 状態が変わったとき。
    var onStatusChange: (HotKeyStatus) -> Void = { _ in }

    convenience init() { self.init(hotKey: GlobalPushToTalkHotKey()) }

    init(hotKey: any HotKeyDriving) {
        self.hotKey = hotKey
        hotKey.onEvent = { [weak self] e in self?.onEvent(e) }
    }

    /// 登録する（動作中なら止めて登録し直す）。
    @discardableResult
    func register(_ combo: HotkeyCombo) -> HotKeyStatus {
        self.combo = combo
        willReset()
        hotKey.stop()
        let newStatus: HotKeyStatus
        do {
            try hotKey.setShortcut(combo.shortcut)
            let backend = try hotKey.start(allowEventTapFallback: true, preferEventTap: false)
            newStatus = .active(backend)
        } catch GlobalPushToTalkHotKey.HotKeyError.alreadyInUse {
            newStatus = .alreadyInUse
        } catch let GlobalPushToTalkHotKey.HotKeyError.registrationFailed(carbonStatus, trusted) {
            newStatus = trusted ? .failed("Carbon \(carbonStatus)") : .needsAccessibility(carbonStatus: Int32(carbonStatus))
        } catch {
            newStatus = .failed(String(describing: error))
        }
        setStatus(newStatus)
        CCLog.hotKey.notice("register \(combo.display, privacy: .public): \(String(describing: newStatus), privacy: .public) (carbon=\(self.hotKey.lastCarbonStatus.map { String($0) } ?? "-", privacy: .public))")
        return newStatus
    }

    /// 失敗していればもう一度登録する（設定変更・オンボーディング完了のとき）。
    func retryIfNeeded() {
        if !status.isActive { register(combo) }
    }

    /// 一時的に止める（ホットキーの診断が同じ組み合わせを登録するため）。
    func suspend() {
        willReset()
        hotKey.stop()
        stopTrustPolling()
        setStatus(.notRegistered)
    }

    private func setStatus(_ s: HotKeyStatus) {
        status = s
        if case .needsAccessibility = s { startTrustPolling() } else { stopTrustPolling() }
        onStatusChange(s)
    }

    private func startTrustPolling() {
        guard trustPoll == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.stopTrustPolling()
                self.register(self.combo)
            }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        trustPoll = t
    }

    private func stopTrustPolling() {
        trustPoll?.invalidate()
        trustPoll = nil
    }
}
