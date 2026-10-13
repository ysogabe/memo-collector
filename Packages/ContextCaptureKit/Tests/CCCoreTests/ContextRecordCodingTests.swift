import CoreGraphics
import XCTest
@testable import CCCore

final class ContextRecordCodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private let jst = TimeZone(identifier: "Asia/Tokyo")!

    /// PRD §7 の例 JSON を読めて、値が期待どおりに入る。
    func testDecodesPRDExample() throws {
        let r = try CCJSON.decoder().decode(ContextRecord.self, from: fixture("prd_record"))
        XCTAssertEqual(r.id, "01JA9Z3K8Q4V7X2M5N6P8R0T1W")
        XCTAssertEqual(r.capturedAt, CCJSON.parseDate("2026-10-08T14:15:32Z"))
        XCTAssertEqual(r.app, AppInfo(name: "Google Chrome", bundleID: "com.google.Chrome"))
        XCTAssertEqual(r.window?.title, "Support streaming events · Issue #128")
        XCTAssertEqual(r.window?.frame, CGRect(x: 0, y: 38, width: 1440, height: 862))
        XCTAssertEqual(r.url, "https://github.com/opendots/opendots/issues/128")
        XCTAssertEqual(r.extra, [:])
        XCTAssertEqual(r.screenshotPath, "captures/2026/10/08/231532.webp")
        XCTAssertNil(r.maskedScreenshotPath)
        XCTAssertEqual(r.audioPath, "captures/2026/10/08/231532.m4a")
        XCTAssertEqual(r.annotation, Annotation(text: "このissueの修正、Claude Codeにやらせて", sttEngine: "whisper-large-v3-turbo", edited: false))
        XCTAssertEqual(r.triage?.intent, .code)
        XCTAssertEqual(r.triage?.intentConfidence, 0.84)
        XCTAssertEqual(r.triage?.mentionsDatetime, false)
        XCTAssertNil(r.triage?.datetimeProbability)
        XCTAssertEqual(r.triage?.model, "LiquidAI/d1-3B@051bcc4")
        XCTAssertEqual(r.guardInfo.status, .needsReview)
        XCTAssertEqual(r.guardInfo.findings, [SecretFinding(kind: "github_token", bbox: CGRect(x: 0.1, y: 0.25, width: 0.3, height: 0.05))])
        XCTAssertEqual(r.handoffs, [Handoff(to: "claude-code", at: CCJSON.parseDate("2026-10-09T00:00:00Z")!, via: "mcp")])
        XCTAssertEqual(r.notes, [])
        XCTAssertEqual(r.status, .inbox)
    }

    /// 読む → 書く → 読むで値が変わらず、書いた JSON は PRD の例のキー・値を（null 以外）すべて含む。
    func testRoundTripPreservesPRDJSON() throws {
        let original = try fixture("prd_record")
        let record = try CCJSON.decoder().decode(ContextRecord.self, from: original)
        let encoded = try CCJSON.encoder(timeZone: jst).encode(record)
        let again = try CCJSON.decoder().decode(ContextRecord.self, from: encoded)
        XCTAssertEqual(again, record)

        let prdObject = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        let outObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        XCTAssertTrue(isSubset(prdObject, of: outObject), "encoded: \(String(decoding: encoded, as: UTF8.self))")
        // 追加フィールドは null / 空で出る
        XCTAssertTrue(outObject["masked_screenshot"] is NSNull)
        XCTAssertEqual((outObject["notes"] as? [Any])?.count, 0)
    }

    /// 日時は指定タイムゾーンのオフセット付きで書く（PRD の例と同じ形）。
    func testDateEncodingKeepsOffset() throws {
        let date = try XCTUnwrap(CCJSON.parseDate("2026-10-08T23:15:32+09:00"))
        XCTAssertEqual(CCJSON.formatDate(date, timeZone: jst), "2026-10-08T23:15:32+09:00")
        let ms = date.addingTimeInterval(0.25)
        XCTAssertEqual(CCJSON.formatDate(ms, timeZone: jst), "2026-10-08T23:15:32.250+09:00")
        XCTAssertEqual(CCJSON.parseDate("2026-10-08T23:15:32.250+09:00"), ms)
        XCTAssertNil(CCJSON.parseDate("2026/10/08"))
    }

    /// 最小限のフィールドだけの JSON（新規保存直後に相当）も読め、既定値が入る。
    func testDecodesMinimalRecordWithDefaults() throws {
        let json = #"""
        {"id":"01JA9Z3K8Q4V7X2M5N6P8R0T1W","captured_at":"2026-10-08T14:15:32Z",
         "app":{"name":"Finder","bundle_id":null},"annotation":{"text":"メモ"}}
        """#
        let r = try CCJSON.decoder().decode(ContextRecord.self, from: Data(json.utf8))
        XCTAssertNil(r.window)
        XCTAssertNil(r.url)
        XCTAssertNil(r.triage)
        XCTAssertNil(r.annotation.sttEngine)
        XCTAssertFalse(r.annotation.edited)
        XCTAssertEqual(r.guardInfo, GuardInfo(status: .pending, findings: []))
        XCTAssertEqual(r.status, .inbox)
    }

    /// 全フィールド（PRD 外の追加分と未分類の triage を含む）の往復。
    func testRoundTripFullRecord() throws {
        let at = try XCTUnwrap(CCJSON.parseDate("2026-10-08T23:15:32.123+09:00"))
        let record = ContextRecord(
            id: ULID.generate(now: at).string,
            capturedAt: at,
            app: AppInfo(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
            window: WindowInfo(title: nil, frame: CGRect(x: 10.5, y: 20, width: 800, height: 600)),
            url: nil,
            extra: ["cwd": "/tmp"],
            screenshotPath: "captures/2026/10/08/x.webp",
            maskedScreenshotPath: "captures/2026/10/08/x-masked.webp",
            audioPath: nil,
            annotation: Annotation(text: "あとで調べる", sttEngine: "whisper-large-v3-turbo", edited: true),
            triage: TriageResult(probabilities: [.research: 0.55, .note: 0.30, .todo: 0.15], datetimeProbability: 0.8, model: "m"),
            guardInfo: GuardInfo(status: .masked, findings: [SecretFinding(kind: "password", bbox: CGRect(x: 0, y: 0, width: 1, height: 0.1))]),
            handoffs: [Handoff(to: "hermes", at: at, via: "mcp")],
            notes: [Note(author: "claude-code", text: "PR #12 で対応", at: at)],
            status: .done
        )
        let data = try CCJSON.encoder(timeZone: jst).encode(record)
        let decoded = try CCJSON.decoder().decode(ContextRecord.self, from: data)
        XCTAssertEqual(decoded, record)

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let triage = try XCTUnwrap(obj["triage"] as? [String: Any])
        XCTAssertTrue(triage["intent"] is NSNull, "未分類は null で書く")
        // 確率の辞書は JSON オブジェクトになる（配列にならない）
        XCTAssertEqual((triage["intent_probabilities"] as? [String: Double])?["research"], 0.55)
        XCTAssertEqual((obj["guard"] as? [String: Any])?["status"] as? String, "masked")
    }

    func testGuardStatusRawValuesAndHandoffPolicy() {
        XCTAssertEqual(GuardStatus.allCases.map(\.rawValue), ["pending", "clear", "needs_review", "masked"])
        XCTAssertEqual(GuardStatus.allCases.filter(\.allowsImageHandoff), [.clear, .masked])
        XCTAssertEqual(RecordStatus.allCases.map(\.rawValue), ["inbox", "done", "archived"])
        XCTAssertEqual(Intent.allCases.map(\.rawValue), ["todo", "research", "code", "note", "schedule"])
    }

    func testRejectsMalformedRect() {
        let json = #"{"title":"t","frame":[1,2,3]}"#
        XCTAssertThrowsError(try CCJSON.decoder().decode(WindowInfo.self, from: Data(json.utf8)))
    }

    /// a の全キーが b にあり、値が等しい（null は「無い」と同じ扱い）。
    private func isSubset(_ a: NSDictionary, of b: NSDictionary) -> Bool {
        for (k, v) in a {
            guard let bv = b[k] else { return v is NSNull }
            if let ad = v as? NSDictionary {
                guard let bd = bv as? NSDictionary, isSubset(ad, of: bd) else { return false }
            } else if let aa = v as? NSArray {
                guard let ba = bv as? NSArray, aa.count == ba.count else { return false }
                for (x, y) in zip(aa, ba) {
                    if let xd = x as? NSDictionary {
                        guard let yd = y as? NSDictionary, isSubset(xd, of: yd) else { return false }
                    } else if !(x as AnyObject).isEqual(y) { return false }
                }
            } else if !(v as AnyObject).isEqual(bv) {
                return false
            }
        }
        return true
    }
}
