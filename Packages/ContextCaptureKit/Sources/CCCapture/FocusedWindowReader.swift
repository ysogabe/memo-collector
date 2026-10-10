import AppKit
import ApplicationServices
import CCCore
import Foundation

/// 前面アプリ（NSWorkspace。権限不要）。
struct FrontmostApp: Sendable, Equatable {
    var name: String
    var bundleID: String?
    var pid: pid_t
}

protocol FrontmostAppProviding: Sendable {
    func frontmostApp() -> FrontmostApp?
}

struct WorkspaceFrontmostAppProvider: FrontmostAppProviding {
    func frontmostApp() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        return FrontmostApp(name: name, bundleID: app.bundleIdentifier, pid: app.processIdentifier)
    }
}

/// フォーカス中ウインドウのタイトルと frame（AX）。
protocol FocusedWindowReading: Sendable {
    /// 権限が無い・取れないときは nil。期限は呼び出し側が付ける。
    func focusedWindow(pid: pid_t) async -> WindowInfo?
}

/// Accessibility API による読み取り。対象アプリの属性は**読むだけ**（`AXManualAccessibility` 等は書き換えない）。
/// AX 呼び出しはブロックするので専用キューで走らせ、1 回の問い合わせの上限を `messagingTimeout` 秒にする（既定は 6 秒）。
struct AXFocusedWindowReader: FocusedWindowReading {
    private static let queue = DispatchQueue(label: "CCCapture.AX", qos: .userInitiated, attributes: .concurrent)
    var messagingTimeout: Float = 0.25

    func focusedWindow(pid: pid_t) async -> WindowInfo? {
        let timeout = messagingTimeout
        return await runBlocking(on: Self.queue) {
            Self.read(pid: pid, messagingTimeout: timeout)
        }
    }

    static func read(pid: pid_t, messagingTimeout: Float) -> WindowInfo? {
        // 権限が無いと kAXErrorAPIDisabled が返る（ダイアログは出ない）が、無駄な IPC を避けるため先に見る。
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else {
            return nil
        }
        let title = string(window, kAXTitleAttribute)
        let frame = frameOf(window)
        if title == nil, frame == nil { return nil }
        return WindowInfo(title: title, frame: frame)
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = copy(el, attr) as? String else { return nil }
        return v
    }

    /// AX の位置は CG のグローバル座標（左上原点・ポイント）。SCWindow.frame と同じ座標系。
    private static func frameOf(_ el: AXUIElement) -> CGRect? {
        guard let p = copy(el, kAXPositionAttribute), let s = copy(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }
}
