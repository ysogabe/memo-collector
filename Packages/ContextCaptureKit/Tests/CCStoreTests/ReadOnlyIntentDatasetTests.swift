import CCCore
import CCStore
import Foundation
import GRDB
import XCTest

final class ReadOnlyIntentDatasetTests: XCTestCase {
    func testReadOnlyLegacySchemaFiltersManualLabelsAndDoesNotMigrate() throws {
        let root = try TempDataRoot()
        let url = root.paths.databaseURL
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE records (id TEXT PRIMARY KEY, captured_at TEXT, intent TEXT, json TEXT); PRAGMA user_version = 1")
            for (i, model, fixture, text, intent) in [(0, "user", false, "正解", "code"), (1, "model", false, "推定", "code"),
                                                   (2, "user", true, "合成", "code"), (3, "user", false, "  ", "code"), (4, "user", false, "未分類", "")] {
                var record = makeRecord(id: "sample-\(i)", at: Double(i), intent: Intent(rawValue: intent), text: text)
                record.triage?.model = model
                if fixture { record.extra["dev_fixture"] = "true" }
                try db.execute(sql: "INSERT INTO records VALUES (?, ?, ?, ?)", arguments: [record.id, "\(i)", Intent(rawValue: intent)?.rawValue,
                                                                                            String(decoding: CCJSON.encoder().encode(record), as: UTF8.self)])
            }
        }
        try db.close()
        let before = try Data(contentsOf: url)
        let dataset = try ReadOnlyIntentDataset.load(databaseURL: url)
        XCTAssertEqual(dataset.totalRecords, 5)
        XCTAssertEqual(dataset.samples.map(\.id), ["sample-0"])
        XCTAssertEqual(dataset.samples[0].truth, .code)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let inspected = try DatabaseQueue(path: url.path)
        XCTAssertEqual(try inspected.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 1)
        XCTAssertEqual(try inspected.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master WHERE name = 'grdb_migrations'") }, 0)
    }
    func testMissingDatabaseIsNotCreated() throws {
        let root = try TempDataRoot()
        XCTAssertThrowsError(try ReadOnlyIntentDataset.load(databaseURL: root.paths.databaseURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.paths.databaseURL.path))
    }
}
