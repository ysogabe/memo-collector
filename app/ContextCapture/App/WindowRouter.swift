import AppKit
import CCCore
import SwiftUI

/// Inbox・設定・オンボーディング・スクショ拡大のウインドウを持つ。
/// メニューバー常駐アプリ（LSUIElement）では SwiftUI の Window / openWindow が裏に開くことがあるため、AppKit で管理する。
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var inbox: NSWindow?
    private var settings: NSWindow?
    private var onboarding: NSWindow?
    private var zoom: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func showInbox() {
        if inbox == nil {
            let vm = InboxViewModel(store: model.env.store, search: model.env.search, now: model.env.now) { [weak model] in
                model?.recordsDidChange()
            }
            let w = makeWindow(title: "Context Inbox", size: NSSize(width: 780, height: 600),
                               root: InboxView(app: model, vm: vm), resizable: true)
            w.setFrameAutosaveName("ContextInbox")
            inbox = w
        }
        present(inbox!)
    }

    func showSettings() {
        if settings == nil {
            let vm = SettingsViewModel(store: model.env.settings)
            settings = makeWindow(title: "設定", size: NSSize(width: 560, height: 720), root: SettingsView(vm: vm), resizable: false)
        }
        present(settings!)
    }

    func showOnboarding() {
        if onboarding == nil {
            let vm = OnboardingViewModel(permissions: model.env.permissions, models: model.env.models) { [weak self] in
                guard let self else { return }
                var s = self.model.settings
                s.onboardingCompleted = true
                self.model.updateSettings(s)
                self.onboarding?.close()
            }
            onboarding = makeWindow(title: "Context Capture へようこそ", size: NSSize(width: 640, height: 600),
                                    root: OnboardingView(vm: vm, hotkey: model.settings.hotkey.display,
                                                        hotKeyIssue: { [weak model] in model?.hotKeyIssue }),
                                    resizable: false)
        }
        present(onboarding!)
    }

    func showScreenshot(_ image: NSImage, findings: [SecretFinding], title: String) {
        zoom?.close()
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = min(1, min(screen.width * 0.85 / max(image.size.width, 1), screen.height * 0.85 / max(image.size.height, 1)))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let root = ScreenshotView(image: image, findings: findings)
            .padding(8)
            .onExitCommand { [weak self] in self?.zoom?.close() }
        let w = makeWindow(title: title, size: NSSize(width: size.width + 16, height: size.height + 16), root: root, resizable: true)
        zoom = w
        present(w)
    }

    private func makeWindow<V: View>(title: String, size: NSSize, root: V, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: root)
        w.setContentSize(size)
        w.center()
        w.delegate = self
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        // 閉じたら作り直す（次に開いたとき最新の状態で始める）。Inbox は位置だけ覚える。
        if w === inbox { inbox = nil }
        if w === settings { settings = nil }
        if w === onboarding { onboarding = nil }
        if w === zoom { zoom = nil }
    }
}
