import Foundation

/// 注釈テキストを意図推定（d1）に渡す前の前処理（純粋関数）。
public enum AnnotationPreprocessor {
    /// d1 に渡す注釈の最大文字数（`Character` 単位。先頭を残す）。
    ///
    /// 根拠: Push-to-Talk の注釈は 1 分話しても日本語で 300〜400 文字程度。d1-3B のトークナイザで日本語はおおむね
    /// 1 文字 ≒ 1 トークンなので、600 文字 + 質問文（約 150 トークン）で 1 forward 750 トークン前後に収まり、
    /// 2 forward（意図・日時）でも p50 0.85 秒（短文）から数秒以内に留まる。コンテキスト長（数万トークン）には十分余裕がある。
    /// 意図は冒頭で述べられることが多いので、切るのは末尾側。
    public static let maxCharacters = 600

    /// `<|im_end|>` のような特殊トークンの文字列（d1 のトークナイザは文中でも特殊トークンとして切り出すため、
    /// 残すとプロンプトの構造が壊れる）。
    static let specialToken = try! NSRegularExpression(pattern: #"<\|[^<>|\n]{0,64}\|>"#)

    /// 特殊トークン文字列を除去 → 前後の空白・改行を除去 → `maxCharacters` で切り詰め。空なら空文字列。
    public static func prepare(_ text: String, maxCharacters: Int = maxCharacters) -> String {
        let stripped = stripSpecialTokens(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.count > maxCharacters else { return stripped }
        return String(stripped.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 特殊トークン文字列だけを除去する（埋め込みにはこちらを使い、切り詰めは埋め込み側に任せる）。
    public static func stripSpecialTokens(_ text: String) -> String {
        let ns = text as NSString
        return specialToken.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
}
