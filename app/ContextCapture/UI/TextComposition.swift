import AppKit

/// IME で変換中（未確定文字がある）か。変換中の Esc / ↓ は IME のものなので、アプリ側で奪わず渡す。
/// キーは key window の first responder にだけ届くので、そこを見る。
@MainActor
func isComposingText() -> Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
}
