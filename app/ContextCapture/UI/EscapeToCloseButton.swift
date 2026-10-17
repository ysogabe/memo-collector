import SwiftUI

/// Esc で閉じるための不可視ボタン。フォーカスがどこにあっても効くようキー割り当てで受ける（⌘F と同じ流儀）。
/// `.onExitCommand` は first responder が NSWindow 自体のとき SwiftUI に届かないので、これを使う。
struct EscapeToCloseButton: View {
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(.cancelAction)
            .disabled(disabled)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
