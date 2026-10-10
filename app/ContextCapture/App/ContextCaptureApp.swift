import CCCore
import SwiftUI

/// アプリのエントリポイント。Dock に出さず（Info.plist の LSUIElement）、メニューバーにだけ常駐する（F-01）。
/// Wave 2 で AppDelegate / AppCoordinator をここに配線する。
@main
struct ContextCaptureApp: App {
    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: "camera.viewfinder")
                .accessibilityLabel("Context Capture")
        }
        .menuBarExtraStyle(.menu)
    }
}
