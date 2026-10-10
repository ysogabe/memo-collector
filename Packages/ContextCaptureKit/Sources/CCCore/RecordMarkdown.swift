import Foundation

/// 記録 1 件を Markdown にする（PRD F-08「Markdown でコピー」）。Foundation だけに依存する純粋関数。
///
/// 出力の形:
/// ```
/// ## 2026-10-08 22:48 · Visual Studio Code
///
/// - ウインドウ: adapter.ts — mach-runtime
/// - URL: <https://example.com>
/// - 意図: code（日時の言及あり）
///
/// > ここで null になる理由を調べて直しておいて
///
/// ![スクショ](captures/2026/10/08/<id>.webp)
///
/// ### メモ
/// - claude-code（2026-10-09 10:00）: 原因は lookup()
/// ```
///
/// スクショのリンクは秘密情報ガード（F-10）に従う。コピーした Markdown はそのまま外部（エージェント）へ渡りうるため、
/// `clear` は元画像、`masked` はマスク版を指し、`needs_review` と `pending`（未スキャン）はリンクを出さない。
public enum RecordMarkdown {
    /// - Parameters:
    ///   - record: 対象の記録。
    ///   - includeScreenshotLink: true ならスクショへのリンク（データルートからの相対パス）を付ける。
    ///   - timeZone: 見出しとメモの時刻を表すタイムゾーン（テストで固定するため注入できる）。
    public static func render(
        _ record: ContextRecord,
        includeScreenshotLink: Bool = false,
        timeZone: TimeZone = .current
    ) -> String {
        var blocks: [String] = []

        blocks.append("## \(format(record.capturedAt, timeZone: timeZone)) · \(singleLine(record.app.name))")

        var meta: [String] = []
        if let title = record.window?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            meta.append("- ウインドウ: \(singleLine(title))")
        }
        if let url = record.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            meta.append("- URL: <\(url)>")
        }
        if let triage = record.triage {
            var line = "- 意図: \(triage.intent?.rawValue ?? unclassifiedLabel)"
            if triage.mentionsDatetime { line += "（日時の言及あり）" }
            meta.append(line)
        }
        if record.guardInfo.status == .needsReview {
            meta.append("- 要確認: スクショにトークンらしき文字列が写っています（画像は含めていません）")
        }
        if !meta.isEmpty { blocks.append(meta.joined(separator: "\n")) }

        let text = record.annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.append(text
                .components(separatedBy: .newlines)
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n"))
        }

        if includeScreenshotLink, let path = handoffScreenshotPath(record) {
            blocks.append("![スクショ](<\(path)>)")
        }

        if !record.notes.isEmpty {
            var lines = ["### メモ"]
            for note in record.notes {
                let body = note.text
                    .components(separatedBy: .newlines)
                    .joined(separator: "\n  ")
                lines.append("- \(singleLine(note.author))（\(format(note.at, timeZone: timeZone))）: \(body)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// 意図が未分類のときの表示名。
    public static let unclassifiedLabel = "未分類"

    /// 外部へ渡してよいスクショの相対パス。ガードが許さない状態・スクショが無いときは nil。
    public static func handoffScreenshotPath(_ record: ContextRecord) -> String? {
        switch record.guardInfo.status {
        case .clear: return record.screenshotPath
        case .masked: return record.maskedScreenshotPath
        case .needsReview, .pending: return nil
        }
    }

    private static func format(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    /// 見出しや箇条書きの 1 行に入れる値の改行を空白にする（Markdown の構造を壊さないため）。
    private static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ")
    }
}
