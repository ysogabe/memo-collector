import CCCore
import Foundation
import SearchEvaluation
@testable import SearchPoC
import XCTest
final class SearchPoCTests: XCTestCase {
    func record(_ id: String, title: String, url: String? = nil, status: RecordStatus = .inbox) -> ContextRecord {
        ContextRecord(id: id, capturedAt: Date(timeIntervalSince1970: 0), app: .unknown,
                      window: WindowInfo(title: title, frame: nil), url: url,
                      annotation: Annotation(text: title, sttEngine: "synthetic"), status: status)
    }
    func testJapaneseShortTermsAndIssueBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try KeywordIndex(records: [record("a", title: "日本語検索の方針 Issue #6", url: "https://example.invalid/issues/6"),
                                                record("b", title: "日本語検索の方針 Issue #60", url: "https://example.invalid/issues/60")], file: root.appendingPathComponent("index.sqlite"))
        XCTAssertEqual(Set(try index.search("検索", includeArchived: false, trigram: true, limit: 10).map(\.recordID)), ["a","b"])
        XCTAssertEqual(try index.search("#6", includeArchived: false, trigram: true, limit: 10).map(\.recordID), ["a"])
        XCTAssertEqual(try index.search("日本語検索", includeArchived: false, trigram: false, limit: 10).count, 0)
        XCTAssertEqual(try index.search("日本語検索", includeArchived: false, trigram: true, limit: 10).count, 2)
        XCTAssertEqual(try index.search("https://example.invalid/issues/6", includeArchived: false, trigram: true, limit: 10).map(\.recordID), ["a"])
    }
    func testIdentifierDoesNotMatchInsideOtherNamesAndArchivedIsFilteredBeforeLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try KeywordIndex(records: [record("a", title: "API sample"),record("z",title:"API hidden",status:.archived),record("b",title:"APIToken")], file:root.appendingPathComponent("index.sqlite"))
        let hits = try index.search("ＡＰＩ", includeArchived: false, trigram: true, limit: 1)
        XCTAssertEqual(hits.map(\.recordID), ["a"])
        XCTAssertEqual(hits.first?.evidence.first?.matchedText, "API")
    }
    func testRRFUsesRanksAndDeduplicatesEachSource() {
        let a = RankedItem(recordID: "a",score: 100), b = RankedItem(recordID: "b",score: -100)
        let fused = Fusion.rrf([[a,a,b],[b]], limit: 2)
        XCTAssertEqual(fused.map(\.recordID), ["b","a"])
        XCTAssertEqual(fused.first?.score ?? 0, 1.0 / 62 + 1.0 / 61, accuracy: 1e-12)
        XCTAssertTrue(Fusion.gate([a],threshold:0.2,exactLookup:true).isEmpty)
    }
}
