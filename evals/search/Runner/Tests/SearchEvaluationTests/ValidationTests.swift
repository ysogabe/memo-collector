import CCCore
import Foundation
import XCTest
@testable import SearchEvaluation
final class ValidationTests: XCTestCase {
    let id = "01JSEARCH00000000000000001"
    func corpus(split: String = "dev", screen: String? = nil) -> Corpus {
        let record = ContextRecord(id: id, capturedAt: Date(timeIntervalSince1970: 0), app: .unknown,
                                   annotation: Annotation(text: "日本語検索", sttEngine: "synthetic"))
        return Corpus(schemaVersion: 1, corpusID: "test", records: [RecordFixture(record: record, group: "topic", split: split, screen: screen)])
    }
    func query(split: String = "dev", relevant: [Relevant]? = nil) -> QueryFixture {
        QueryFixture(id: "q", text: "日本語検索", relevant: relevant ?? [Relevant(id)], tags: ["japanese"], group: "topic", split: split, includeArchived: false)
    }
    func testRejectsCrossSplitRelevanceAndDuplicateRecordIDs() throws {
        XCTAssertNoThrow(try QuerySet(schemaVersion: 1, corpusID: "test", queries: [query()]).validate(corpus: corpus()))
        XCTAssertThrowsError(try QuerySet(schemaVersion: 1, corpusID: "test", queries: [query(split: "holdout")]).validate(corpus: corpus()))
        var c = corpus(); c.records.append(c.records[0])
        XCTAssertThrowsError(try c.validate())
    }
    func testRejectsInvalidGroundTruthAndPaths() throws {
        for rel in [[Relevant("missing")], [Relevant(id, grade: 0)], [Relevant(id), Relevant(id)]] {
            XCTAssertThrowsError(try QuerySet(schemaVersion: 1, corpusID: "test", queries: [query(relevant: rel)]).validate(corpus: corpus()))
        }
        XCTAssertThrowsError(try corpus(screen: "../private.png").validate())
        XCTAssertThrowsError(try corpus(screen: "/private/personal.png").validate())
    }
    func testRejectsQueryTextLeakingAcrossSplitEvenWithNoAnswers() throws {
        var other = query(split: "holdout", relevant: []); other.id = "q2"; other.group = "none"
        XCTAssertThrowsError(try QuerySet(schemaVersion: 1, corpusID: "test", queries: [query(), other]).validate(corpus: corpus()))
    }
}
