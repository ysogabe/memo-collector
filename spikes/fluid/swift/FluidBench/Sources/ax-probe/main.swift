// 読み取り専用の AX 動作確認。前面アプリ・フォーカスウインドウのタイトル / AXDocument / AXURL・選択テキスト、
// AX ツリーの浅い走査（要素数）を出す。FluidUse の公開 API は isTrusted / candidates() だけを使う
// （AccessibilityFormDriver の init は対象アプリに AXEnhancedUserInterface を書き込む副作用があるため呼ばない）。
import AppKit
import ApplicationServices
import FluidUse

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func walk(_ e: AXUIElement, depth: Int, budget: inout Int, roles: inout [String: Int]) {
    guard budget > 0, depth < 12 else { return }
    budget -= 1
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    roles[role, default: 0] += 1
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1, budget: &budget, roles: &roles) }
}

let trusted = await MainActor.run { AccessibilityFormDriver.isTrusted }
print("AXIsProcessTrusted:", trusted)
let candidates = await MainActor.run { AccessibilityFormDriver.candidates().map { $0.localizedName ?? "?" } }
print("FluidUse candidates() count:", candidates.count)
guard let app = NSWorkspace.shared.frontmostApplication else { print("no frontmost app"); exit(0) }
print("frontmost:", app.localizedName ?? "?", app.bundleIdentifier ?? "?")
guard trusted else { print("Accessibility 権限が無いため AX 読み取りは未検証"); exit(0) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
if let w = attr(ax, kAXFocusedWindowAttribute) {
    let win = w as! AXUIElement
    print("window title:", attr(win, kAXTitleAttribute) as? String ?? "nil")
    print("AXDocument:", attr(win, kAXDocumentAttribute) as? String ?? "nil")
    print("AXURL:", (attr(win, kAXURLAttribute)).map { "\($0)" } ?? "nil")
    var budget = 3000
    var roles: [String: Int] = [:]
    walk(win, depth: 0, budget: &budget, roles: &roles)
    print("AX tree nodes visited:", 3000 - budget, "top roles:", roles.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)=\($0.value)" })
} else { print("focused window: nil") }
if let f = attr(ax, kAXFocusedUIElementAttribute) {
    let sel = attr(f as! AXUIElement, kAXSelectedTextAttribute) as? String
    print("selected text length:", sel.map { $0.count } ?? -1)
}
