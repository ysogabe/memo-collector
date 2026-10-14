import CCCore
import CCStore
import Foundation
import XCTest

final class DevelopmentFixtureTests: XCTestCase {
    func testDuplicateFixtureRollsBackTheEntireBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteRecordStore(paths: CCPaths(dataRoot: root, modelsRoot: root))
        let a = ContextRecord(id: "fixture-a", capturedAt: Date(timeIntervalSince1970: 1), app: .unknown,
                              annotation: Annotation(text: "synthetic", sttEngine: "fixture"))
        do { try await store.insertBatch([a, a]); XCTFail("duplicate fixture should rollback") } catch {}
        let count = try await store.count(InboxFilter(statuses: []))
        XCTAssertEqual(count, 0)
        try await store.insertBatch([a])
        let record = try await store.get(id: a.id)
        XCTAssertEqual(record, a)
    }

    func testMediaPathsAreRejectedAndSyntheticRecordsAreMarked() throws {
        struct Entry: Encodable { var record: ContextRecord }
        struct Envelope: Encodable { var records: [Entry] }
        var record = ContextRecord(id: "fixture", capturedAt: Date(timeIntervalSince1970: 1), app: .unknown,
                                   annotation: Annotation(text: "synthetic", sttEngine: "fixture"))
        var data = try CCJSON.encoder().encode(Envelope(records: [Entry(record: record)]))
        let loaded = try DevelopmentFixtures.load(data)
        XCTAssertEqual(loaded[0].extra["dev_fixture"], "true")
        record.audioPath = "captures/unknown.wav"
        data = try CCJSON.encoder().encode(Envelope(records: [Entry(record: record)]))
        XCTAssertThrowsError(try DevelopmentFixtures.load(data))
    }
}
