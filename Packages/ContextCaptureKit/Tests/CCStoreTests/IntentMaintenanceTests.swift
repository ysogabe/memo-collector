import CCCore
import Foundation
import GRDB
import XCTest
@testable import CCStore

final class IntentMaintenanceTests: XCTestCase {
    private func backupURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("intent-backup-\(UUID().uuidString).sqlite")
    }

    func testPreviewIsReadOnlyAndCountsBoundaryWithoutModelsOrAttachments() throws {
        let root = try TempDataRoot()
        let db = try DatabaseQueue(path: root.paths.databaseURL.path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE records(id TEXT PRIMARY KEY, captured_at REAL, intent TEXT, has_triage INTEGER, json TEXT); PRAGMA user_version=17")
            for (id, confidence, model, text) in [("boundary", 0.6, "old-model", "合成の非公開注釈"), ("below", 0.599, "old-model", "資料"),
                                                  ("manual", 0.8, "user", "手動正解"), ("empty", 0.8, "old-model", "  ")] {
                var r = makeRecord(id: id, intent: .code, text: text)
                r.screenshotPath = "captures/does-not-exist.png"
                r.triage = TriageResult(probabilities: [.code: confidence, .todo: (1 - confidence) / 4, .research: (1 - confidence) / 4,
                                                       .note: (1 - confidence) / 4, .schedule: (1 - confidence) / 4], datetimeProbability: 0.2, model: model)
                try db.execute(sql: "INSERT INTO records VALUES (?, 0, ?, 1, ?)", arguments: [id, r.triage?.intent?.rawValue,
                                                                                           String(decoding: CCJSON.encoder().encode(r), as: UTF8.self)])
            }
        }
        try db.close()
        let before = try Data(contentsOf: root.paths.databaseURL)
        let result = try IntentMaintenance.preview(paths: root.paths)
        XCTAssertEqual(result.totalRecords, 4)
        XCTAssertEqual(result.manualRecords, 1)
        XCTAssertEqual(result.emptyAnnotations, 1)
        XCTAssertEqual(result.eligibleRecords, 2)
        XCTAssertEqual(result.storedClassifiedAt70, 0)
        XCTAssertEqual(result.storedClassifiedAt60, 1)
        XCTAssertEqual(result.storedClassificationChanges70To60, 1)
        XCTAssertEqual(try Data(contentsOf: root.paths.databaseURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.paths.modelsRoot.path))
        let report = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(report.contains("boundary"))
        XCTAssertFalse(report.contains("合成の非公開注釈"))
        XCTAssertFalse(report.contains("captures/"))
    }

    func testMissingCorruptAndSymlinkDatabaseAreRejectedWithoutCreatingAnything() throws {
        let root = try TempDataRoot()
        XCTAssertThrowsError(try IntentMaintenance.preview(paths: root.paths))
        XCTAssertThrowsError(try IntentOnlyRecordStore(paths: root.paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.paths.databaseURL.path))
        try Data("invalid database".utf8).write(to: root.paths.databaseURL)
        XCTAssertThrowsError(try IntentMaintenance.preview(paths: root.paths))
        XCTAssertEqual(try Data(contentsOf: root.paths.databaseURL), Data("invalid database".utf8))
        try FileManager.default.removeItem(at: root.paths.databaseURL)
        let outside = backupURL()
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("source sentinel".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.paths.databaseURL, withDestinationURL: outside)
        XCTAssertThrowsError(try IntentMaintenance.preview(paths: root.paths))
        XCTAssertEqual(try Data(contentsOf: outside), Data("source sentinel".utf8))
    }

    func testBackupIncludesWALAndIsPrivateAndCannotOverwriteFiles() async throws {
        let root = try TempDataRoot()
        let store = try root.makeStore()
        let r = makeRecord(intent: .code)
        try await store.insert(r)
        let url = backupURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try IntentMaintenance.backup(paths: root.paths, to: url)
        let db = try DatabaseQueue(path: url.path)
        let restoredID = try await db.read { try String.fetchOne($0, sql: "SELECT id FROM records") }
        let integrity = try await db.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
        XCTAssertEqual(restoredID, r.id)
        XCTAssertEqual(integrity, "ok")
        try db.close()
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try IntentMaintenance.backup(paths: root.paths, to: url))
        XCTAssertThrowsError(try IntentMaintenance.backup(paths: root.paths, to: root.paths.databaseURL))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testReportProtectsInputBackupDataAndModelRootsAndSymlinks() throws {
        let root = try TempDataRoot()
        let backup = backupURL()
        defer { try? FileManager.default.removeItem(at: backup) }
        try Data("backup sentinel".utf8).write(to: backup)
        for url in [root.paths.databaseURL, root.paths.dataRoot.appendingPathComponent("report.json"),
                    root.paths.modelsRoot.appendingPathComponent("report.json"), backup] {
            XCTAssertThrowsError(try IntentMaintenance.writeReport(Data(), to: url, paths: root.paths, protected: [backup]))
        }
        let alias = backupURL()
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: backup)
        XCTAssertThrowsError(try IntentMaintenance.writeReport(Data(), to: alias, paths: root.paths, protected: [backup]))
        XCTAssertEqual(try Data(contentsOf: backup), Data("backup sentinel".utf8))
    }

    func testIntentOnlyWritePreservesNonTriageJSONAndAllIndexStateAndRollsBack() async throws {
        let root = try TempDataRoot()
        let store = try root.makeStore()
        var original = makeRecord(id: "authored", intent: .research)
        original.url = "https://example.invalid/synthetic"
        original.audioPath = "captures/absent.wav"
        original.extra["synthetic"] = "yes"
        try await store.insert(original)
        try await store.setEmbedding(id: original.id, vector: unitVector([0: 1]))
        let db = try DatabaseQueue(path: root.paths.databaseURL.path)
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO index_generations VALUES('active','active-key','{}','active');
                INSERT INTO index_generations VALUES('building','building-key','{}','building');
                UPDATE index_generation_pointer SET active_id='active', target_id='building' WHERE id=1;
                INSERT INTO generation_embeddings VALUES('authored','active',0,'hash',1,x'0000803f');
                INSERT INTO generation_jobs VALUES('authored','building',0,'pending',2);
                UPDATE records SET json=json_set(json,'$.unknown_field',json('{"keep":"sentinel"}')) WHERE id='authored';
                """)
        }
        let tables = ["sqlite_master", "embeddings", "embeddings_version", "record_input_versions", "index_generations", "index_generation_pointer", "generation_embeddings", "generation_jobs"]
        func snapshot() throws -> [[Row]] { try db.read { db in try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") } } }
        let before = try snapshot()
        let originalOtherJSON = try await db.read { try String.fetchOne($0, sql: "SELECT json_remove(json,'$.triage') FROM records") }
        let maintenance = try IntentOnlyRecordStore(paths: root.paths)
        let result = TriageResult(probabilities: [.code: 0.6, .todo: 0.1, .research: 0.1, .note: 0.1, .schedule: 0.1], datetimeProbability: 0.3, model: "synthetic-d1")
        try await maintenance.modify(id: original.id) { $0.triage = result }
        let saved = try await maintenance.get(id: original.id)
        XCTAssertEqual(saved?.triage?.intent, .code)
        XCTAssertEqual(maintenance.changedResults, 1)
        XCTAssertEqual(maintenance.changedClassifications, 1)
        XCTAssertEqual(try snapshot(), before)
        let updatedOtherJSON = try await db.read { try String.fetchOne($0, sql: "SELECT json_remove(json,'$.triage') FROM records") }
        XCTAssertEqual(updatedOtherJSON, originalOtherJSON)
        do {
            try await maintenance.modify(id: original.id) { $0.notes.append(Note(author: "test", text: "forbidden", at: Date())) }
            XCTFail("non-intent writes must throw")
        } catch {}
        let afterFailure = try await maintenance.get(id: original.id)
        XCTAssertEqual(afterFailure, saved)
        XCTAssertEqual(try snapshot(), before)
        try db.close()
    }

    func testManualProbabilitiesArePreservedAndUnsupportedOperationsThrow() async throws {
        let root = try TempDataRoot()
        let store = try root.makeStore()
        var original = makeRecord(intent: .code)
        original.triage?.model = "user"
        original.triage?.intentProbabilities = [.code: 0.6, .todo: 0.1, .research: 0.1, .note: 0.1, .schedule: 0.1]
        try await store.insert(original)
        let maintenance = try IntentOnlyRecordStore(paths: root.paths)
        do { try await maintenance.modify(id: original.id) { $0.triage?.intent = .todo }; XCTFail("manual") } catch {}
        let saved = try await maintenance.get(id: original.id)
        XCTAssertEqual(saved, original)
        do { try await maintenance.setEmbedding(id: original.id, vector: []); XCTFail("index") } catch {}
        do { _ = try await maintenance.attachmentURL(for: "captures/no-access"); XCTFail("attachment") } catch {}
        XCTAssertEqual(maintenance.changedResults, 0)
    }
}
