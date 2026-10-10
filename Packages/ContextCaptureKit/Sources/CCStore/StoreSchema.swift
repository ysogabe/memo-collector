import CCCore
import Foundation
import GRDB

/// スキーマとマイグレーション。
///
/// - `records`: 絞り込み・並べ替えに使う値だけ列に出し、`ContextRecord` 全体は `json`（CCJSON）に持つ。
///   列は `RecordRow.columns(for:)` だけが作るので、insert / update で JSON と列がずれない。
///   `captured_at` は ISO 文字列ではなく Unix 秒（REAL）。CCJSON は端末のタイムゾーンのオフセットで書くため、
///   文字列のままだと TZ が変わったときに大小比較が壊れる。
/// - `embeddings`: 1 レコード 1 ベクトル（Float32 リトルエンディアンの BLOB）。レコード削除で連鎖削除。
enum StoreSchema {
    static let recordsTable = "records"
    static let embeddingsTable = "embeddings"

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: recordsTable) { t in
                t.primaryKey("id", .text)
                t.column("captured_at", .double).notNull()
                t.column("status", .text).notNull()
                t.column("intent", .text)
                t.column("has_triage", .boolean).notNull()
                t.column("guard_status", .text).notNull()
                t.column("app_bundle_id", .text)
                t.column("app_name", .text).notNull()
                t.column("screenshot_path", .text)
                t.column("masked_screenshot_path", .text)
                t.column("audio_path", .text)
                t.column("json", .text).notNull()
            }
            try db.create(index: "records_on_captured_at", on: recordsTable, columns: ["captured_at"])
            try db.create(index: "records_on_status_captured_at", on: recordsTable, columns: ["status", "captured_at"])
            try db.create(index: "records_on_intent", on: recordsTable, columns: ["intent"])
            try db.create(index: "records_on_guard_status", on: recordsTable, columns: ["guard_status"])
            try db.create(index: "records_on_app_bundle_id", on: recordsTable, columns: ["app_bundle_id"])

            try db.create(table: embeddingsTable) { t in
                t.primaryKey("record_id", .text)
                    .references(recordsTable, column: "id", onDelete: .cascade)
                t.column("dim", .integer).notNull()
                t.column("vector", .blob).notNull()
            }

            // 埋め込みの世代番号。embeddings が変わるたびにトリガで +1 する（別プロセスの変更も含む）。
            // 検索はこれを見て、メモリ上の行列キャッシュを使い回すか読み直すかを決める。
            try db.execute(sql: """
                CREATE TABLE embeddings_version (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    version INTEGER NOT NULL
                );
                INSERT INTO embeddings_version (id, version) VALUES (1, 0);
                CREATE TRIGGER embeddings_after_insert AFTER INSERT ON embeddings
                    BEGIN UPDATE embeddings_version SET version = version + 1 WHERE id = 1; END;
                CREATE TRIGGER embeddings_after_update AFTER UPDATE ON embeddings
                    BEGIN UPDATE embeddings_version SET version = version + 1 WHERE id = 1; END;
                CREATE TRIGGER embeddings_after_delete AFTER DELETE ON embeddings
                    BEGIN UPDATE embeddings_version SET version = version + 1 WHERE id = 1; END;
                """)
        }
        return m
    }
}

/// `records` 行と `ContextRecord` の相互変換。
enum RecordRow {
    /// 列名の並び（INSERT / UPDATE で共用）。
    static let columnNames = [
        "id", "captured_at", "status", "intent", "has_triage", "guard_status",
        "app_bundle_id", "app_name", "screenshot_path", "masked_screenshot_path", "audio_path", "json",
    ]

    /// レコードから列の値を作る（`columnNames` と同じ順）。
    static func values(for record: ContextRecord) throws -> [DatabaseValueConvertible?] {
        let json = try String(decoding: CCJSON.encoder().encode(record), as: UTF8.self)
        return [
            record.id,
            record.capturedAt.timeIntervalSince1970,
            record.status.rawValue,
            record.triage?.intent?.rawValue,
            record.triage != nil,
            record.guardInfo.status.rawValue,
            record.app.bundleID,
            record.app.name,
            record.screenshotPath,
            record.maskedScreenshotPath,
            record.audioPath,
            json,
        ]
    }

    static func decode(_ row: Row) throws -> ContextRecord {
        let id: String = row["id"]
        let json: String = row["json"]
        do {
            return try CCJSON.decoder().decode(ContextRecord.self, from: Data(json.utf8))
        } catch {
            throw CCStoreError.corruptedRow(id: id, reason: "\(error)")
        }
    }

    static func insert(_ record: ContextRecord, db: Database) throws {
        if try exists(id: record.id, db: db) { throw CCStoreError.duplicateID(record.id) }
        let placeholders = Array(repeating: "?", count: columnNames.count).joined(separator: ", ")
        try db.execute(
            sql: "INSERT INTO records (\(columnNames.joined(separator: ", "))) VALUES (\(placeholders))",
            arguments: StatementArguments(values(for: record))
        )
    }

    static func update(_ record: ContextRecord, db: Database) throws {
        let sets = columnNames.dropFirst().map { "\($0) = ?" }.joined(separator: ", ")
        var vals = try values(for: record)
        vals.append(vals.removeFirst())  // id を末尾（WHERE 用）へ
        try db.execute(sql: "UPDATE records SET \(sets) WHERE id = ?", arguments: StatementArguments(vals))
        if db.changesCount == 0 { throw CCStoreError.notFound(record.id) }
    }

    static func fetch(id: String, db: Database) throws -> ContextRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, json FROM records WHERE id = ?", arguments: [id])
        else { return nil }
        return try decode(row)
    }

    static func exists(id: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM records WHERE id = ?)", arguments: [id]) ?? false
    }
}

/// Float32 配列 ⇔ BLOB。
enum VectorCodec {
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// BLOB のアラインメントは保証されないので bindMemory せずコピーする。
    static func decode(_ data: Data, count: Int) -> [Float]? {
        guard data.count == count * MemoryLayout<Float>.size else { return nil }
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
        return out
    }
}
