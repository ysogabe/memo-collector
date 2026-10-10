import SwiftUI

/// メニューバーのメニュー（Wave 0 は名前と「終了」だけ。Inbox・設定は Wave 2 の UI 担当が足す）。
struct MenuBarContent: View {
    var body: some View {
        Text("Context Capture")
        Divider()
        Button("終了") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
