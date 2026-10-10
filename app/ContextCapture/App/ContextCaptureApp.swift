import AppKit
import CCCore
import SwiftUI

/// アプリのエントリポイント。Dock に出さず（Info.plist の LSUIElement）、メニューバーにだけ常駐する（F-01）。
/// 依存の組み立ては `AppEnvironment`、状態は `AppModel`（AppDelegate が 1 つだけ持つ）。
@main
struct ContextCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--render-snapshots <dir>` のときは時計を固定したフェイクで組み立てる（PNG の中身を毎回同じにするため）。
    let model: AppModel = {
        if SnapshotRenderer.requestedDirectory() != nil {
            return AppModel(env: SnapshotRenderer.makeEnvironment())
        }
        return AppModel(env: AppEnvironment.resolve())
    }()

    private var menuTrackingObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = SnapshotRenderer.requestedDirectory() {
            Task { @MainActor in
                let code = await SnapshotRenderer(model: model).renderAll(to: dir)
                exit(code)
            }
            return
        }
        model.start()
        // ⌥ を押しながらメニューバーのメニューを開いたらデバッグメニューを出す（以降このプロセスの間ずっと）。
        // SwiftUI の MenuBarExtra は開く瞬間を知らせないので、メニューの追跡開始の通知で修飾キーを見る。
        // 反映が次に開いたときになることがある（その場合はもう一度開く）。
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.modifierFlags.contains(.option) { self?.model.revealDebugMenu() }
            }
        }
        if !model.settings.onboardingCompleted {
            model.windows.showOnboarding()
        }
    }
}
