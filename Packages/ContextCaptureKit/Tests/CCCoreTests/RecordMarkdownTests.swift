import CoreGraphics
import XCTest
@testable import CCCore

final class RecordMarkdownTests: XCTestCase {
    private let jst = TimeZone(identifier: "Asia/Tokyo")!
    /// 2026-10-08 22:48:10 JST
    private let capturedAt = Date(timeIntervalSince1970: 1_791_467_290)

    private func record(
        window: WindowInfo? = WindowInfo(title: "adapter.ts — mach-runtime", frame: nil),
        url: String? = nil,
        text: String = "ここで null になる理由を調べて直しておいて",
        triage: TriageResult? = nil,
        guardInfo: GuardInfo = GuardInfo(status: .clear),
        notes: [Note] = []
    ) -> ContextRecord {
        ContextRecord(
            id: "01JABCDEFGHJKMNPQRSTVWXYZ0",
            capturedAt: capturedAt,
            app: AppInfo(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
            window: window,
            url: url,
            screenshotPath: "captures/2026/10/08/01JABCDEFGHJKMNPQRSTVWXYZ0.webp",
            maskedScreenshotPath: "captures/2026/10/08/01JABCDEFGHJKMNPQRSTVWXYZ0-masked.webp",
            annotation: Annotation(text: text, sttEngine: "whisper-large-v3-turbo"),
            triage: triage,
            guardInfo: guardInfo,
            notes: notes
        )
    }

    private func triage(_ intent: Intent?, datetime: Bool = false) -> TriageResult {
        TriageResult(intent: intent, intentConfidence: intent == nil ? 0.5 : 0.84, mentionsDatetime: datetime, model: "test")
    }

    func testFullRecord() {
        let r = record(
            url: "https://github.com/opendots/opendots/issues/128",
            triage: triage(.code, datetime: true),
            notes: [Note(author: "claude-code", text: "lookup() が undefined を返すのが原因", at: capturedAt.addingTimeInterval(3600))]
        )
        let md = RecordMarkdown.render(r, includeScreenshotLink: true, timeZone: jst)
        XCTAssertEqual(md, """
        ## 2026-10-08 22:48 · Visual Studio Code

        - ウインドウ: adapter.ts — mach-runtime
        - URL: <https://github.com/opendots/opendots/issues/128>
        - 意図: code（日時の言及あり）

        > ここで null になる理由を調べて直しておいて

        ![スクショ](<captures/2026/10/08/01JABCDEFGHJKMNPQRSTVWXYZ0.webp>)

        ### メモ
        - claude-code（2026-10-08 23:48）: lookup() が undefined を返すのが原因

        """)
    }

    func testMinimalRecordOmitsMissingFields() {
        let r = record(window: nil, url: nil, triage: nil)
        let md = RecordMarkdown.render(r, timeZone: jst)
        XCTAssertEqual(md, """
        ## 2026-10-08 22:48 · Visual Studio Code

        > ここで null になる理由を調べて直しておいて

        """)
    }

    func testEmptyTitleAndURLAreOmitted() {
        let md = RecordMarkdown.render(record(window: WindowInfo(title: "  ", frame: nil), url: ""), timeZone: jst)
        XCTAssertFalse(md.contains("ウインドウ"))
        XCTAssertFalse(md.contains("URL"))
    }

    func testUnclassifiedIntent() {
        let md = RecordMarkdown.render(record(triage: triage(nil)), timeZone: jst)
        XCTAssertTrue(md.contains("- 意図: 未分類\n"), md)
    }

    func testNoTriageMeansNoIntentLine() {
        let md = RecordMarkdown.render(record(triage: nil), timeZone: jst)
        XCTAssertFalse(md.contains("意図"))
    }

    func testMultilineAnnotationIsBlockquotedPerLine() {
        let md = RecordMarkdown.render(record(window: nil, text: "1 行目\n\n3 行目"), timeZone: jst)
        XCTAssertTrue(md.contains("> 1 行目\n>\n> 3 行目"), md)
    }

    func testNewlinesInHeadingValuesAreFlattened() {
        let md = RecordMarkdown.render(record(window: WindowInfo(title: "a\nb", frame: nil)), timeZone: jst)
        XCTAssertTrue(md.contains("- ウインドウ: a b\n"), md)
    }

    func testScreenshotLinkFollowsGuardStatus() {
        func link(_ status: GuardStatus) -> String? {
            let md = RecordMarkdown.render(record(guardInfo: GuardInfo(status: status)), includeScreenshotLink: true, timeZone: jst)
            return md.components(separatedBy: "\n").first { $0.hasPrefix("![") }
        }
        XCTAssertEqual(link(.clear), "![スクショ](<captures/2026/10/08/01JABCDEFGHJKMNPQRSTVWXYZ0.webp>)")
        XCTAssertEqual(link(.masked), "![スクショ](<captures/2026/10/08/01JABCDEFGHJKMNPQRSTVWXYZ0-masked.webp>)")
        XCTAssertNil(link(.needsReview))
        XCTAssertNil(link(.pending))
    }

    func testNeedsReviewIsStated() {
        let findings = [SecretFinding(kind: "github_token", bbox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05))]
        let md = RecordMarkdown.render(record(guardInfo: GuardInfo(status: .needsReview, findings: findings)), timeZone: jst)
        XCTAssertTrue(md.contains("- 要確認: "), md)
    }

    func testNoLinkWhenNotRequested() {
        let md = RecordMarkdown.render(record(), includeScreenshotLink: false, timeZone: jst)
        XCTAssertFalse(md.contains("!["))
    }

    func testNoLinkWhenScreenshotMissing() {
        var r = record()
        r.screenshotPath = nil
        let md = RecordMarkdown.render(r, includeScreenshotLink: true, timeZone: jst)
        XCTAssertFalse(md.contains("!["))
    }
}
