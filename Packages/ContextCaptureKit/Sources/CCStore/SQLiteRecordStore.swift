import Accelerate
import CCCore
import Foundation
import GRDB

/// `RecordStore` の SQLite（GRDB）実装。
///
/// - `DatabasePool`（WAL）で開く。アプリと別プロセスの `cc-mcp` が同じ DB を同時に開く前提で、
///   ロック待ちは `busyTimeout` まで待つ（既定 10 秒）。GRDB の書き込みトランザクションは IMMEDIATE なので、
///   `modify(id:_:)` 系の read-modify-write はプロセスをまたいでも直列化され、上書き事故が起きない。
/// - インスタンスは Sendable（中身は不変の値と `DatabasePool` だけ）。複数作ってよい。
public final class SQLiteRecordStore: RecordStore, Sendable {
    /// 音声の既定保持期間（7 日）。
    public static let defaultAudioRetention: TimeInterval = 7 * 24 * 60 * 60
    /// 埋め込みの既定次元。
    public static let defaultDimension = 256

    public let paths: CCPaths
    /// 埋め込みの次元。`setEmbedding` / `search` はこれと違う長さを `CCStoreError.dimensionMismatch` で拒む。
    public let dimension: Int
    /// 添付パスの日付（`captures/YYYY/MM/DD`）を決めるタイムゾーン。
    public let timeZone: TimeZone

    let pool: DatabasePool
    let embeddingCache = EmbeddingCache()

    /// `paths.databaseURL` を開き（無ければ作り）、マイグレーションを適用する。何度開いても冪等。
    public init(
        paths: CCPaths,
        dimension: Int = SQLiteRecordStore.defaultDimension,
        timeZone: TimeZone = .current,
        busyTimeout: TimeInterval = 10
    ) throws {
        self.paths = paths
        self.dimension = dimension
        self.timeZone = timeZone
        try FileManager.default.createDirectory(at: paths.dataRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.capturesRoot, withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(busyTimeout)
        config.label = "CCStore"
        pool = try DatabasePool(path: paths.databaseURL.path, configuration: config)
        let needsBackup = try pool.read { db in
            guard try db.tableExists("grdb_migrations") else { return false }
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            return migrations.contains("v1") && !migrations.contains("v2_index_generations")
        }
        if needsBackup {
            let backup = paths.databaseURL.appendingPathExtension("pre-index-v2-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                let partial = backup.appendingPathExtension("partial-\(UUID().uuidString)")
                do {
                    let destination = try DatabaseQueue(path: partial.path)
                    try pool.backup(to: destination)
                    try destination.writeWithoutTransaction { db in
                        try db.execute(sql: "PRAGMA journal_mode=DELETE")
                    }
                    try destination.close()
                    do { try FileManager.default.moveItem(at: partial, to: backup) }
                    catch {
                        // Another process may have completed the same migration backup meanwhile.
                        guard FileManager.default.fileExists(atPath: backup.path) else { throw error }
                        try? FileManager.default.removeItem(at: partial)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
            }
            var backupConfig = Configuration(); backupConfig.readonly = true
            let verified = try DatabaseQueue(path: backup.path, configuration: backupConfig)
            let valid = try verified.read { db in
                try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" && db.tableExists("records")
            }
            guard valid else { throw CCStoreError.invalidGeneration("migration backup is invalid") }
        }
        try StoreSchema.migrator.migrate(pool)
    }

    /// `CCPaths.resolve()`（`CC_DATA_DIR` を尊重）の場所で開く。
    public convenience init() throws {
        try self.init(paths: CCPaths.resolve())
    }

    // MARK: - CRUD

    public func insert(_ record: ContextRecord) async throws {
        try await pool.write { db in try RecordRow.insert(record, db: db) }
    }

    /// 開発fixture等を一つのtransactionで投入する。重複/不正な行があれば全件rollbackする。
    public func insertBatch(_ records: [ContextRecord]) async throws {
        try await pool.write { db in
            for record in records { try RecordRow.insert(record, db: db) }
        }
    }

    public func update(_ record: ContextRecord) async throws {
        try await pool.write { db in try RecordRow.update(record, db: db) }
    }

    public func get(id: String) async throws -> ContextRecord? {
        try await pool.read { db in try RecordRow.fetch(id: id, db: db) }
    }

    public func list(_ filter: InboxFilter) async throws -> [ContextRecord] {
        guard filter.limit > 0 else { return [] }
        let (whereSQL, whereArgs) = Self.whereClause(filter)
        let arguments = whereArgs + [filter.limit, max(0, filter.offset)]
        return try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, json FROM records \(whereSQL) ORDER BY captured_at DESC, id DESC LIMIT ? OFFSET ?",
                arguments: arguments
            ).map(RecordRow.decode)
        }
    }

    public func count(_ filter: InboxFilter) async throws -> Int {
        let (whereSQL, arguments) = Self.whereClause(filter)
        return try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records \(whereSQL)", arguments: arguments) ?? 0
        }
    }

    /// `InboxFilter` を WHERE 句にする。
    /// - `statuses` が空なら状態の条件なし。`guardStatuses` が空集合なら 0 件（nil は条件なし）。
    /// - `unclassifiedOnly` は「triage はあるが intent が nil」。`intent` と同時指定すると 0 件。
    static func whereClause(_ filter: InboxFilter) -> (String, StatementArguments) {
        var conds: [String] = []
        var args = StatementArguments()
        if !filter.statuses.isEmpty {
            let values = filter.statuses.map(\.rawValue).sorted()
            conds.append("status IN (\(placeholders(values.count)))")
            args += StatementArguments(values)
        }
        if let intent = filter.intent {
            conds.append("intent = ?")
            args += [intent.rawValue]
        }
        if filter.unclassifiedOnly {
            conds.append("has_triage = 1 AND intent IS NULL")
        }
        if let since = filter.since {
            conds.append("captured_at >= ?")
            args += [since.timeIntervalSince1970]
        }
        if let until = filter.until {
            conds.append("captured_at < ?")
            args += [until.timeIntervalSince1970]
        }
        if let guards = filter.guardStatuses {
            if guards.isEmpty {
                conds.append("0")
            } else {
                let values = guards.map(\.rawValue).sorted()
                conds.append("guard_status IN (\(placeholders(values.count)))")
                args += StatementArguments(values)
            }
        }
        let sql = conds.isEmpty ? "" : "WHERE " + conds.map { "(\($0))" }.joined(separator: " AND ")
        return (sql, args)
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ", ")
    }

    public func delete(id: String) async throws {
        let removed: ContextRecord? = try await pool.write { db in
            guard let record = try RecordRow.fetch(id: id, db: db) else { return nil }
            try db.execute(sql: "DELETE FROM embeddings WHERE record_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM records WHERE id = ?", arguments: [id])
            return record
        }
        guard let removed else { return }
        // DB から消えた後でファイルを消す（逆順だと、途中で落ちたときに「ファイルの無いレコード」が残る）。
        removeFiles([removed.screenshotPath, removed.maskedScreenshotPath, removed.audioPath].compactMap { $0 })
        removeStrayAttachments(id: id, capturedAt: removed.capturedAt)
    }

    // MARK: - 埋め込みと検索

    public func setEmbedding(id: String, vector: [Float]) async throws {
        guard vector.count == dimension else {
            throw CCStoreError.dimensionMismatch(expected: dimension, actual: vector.count)
        }
        guard vector.allSatisfy(\.isFinite) else { throw CCStoreError.invalidVector }
        let blob = VectorCodec.encode(vector)
        let dim = dimension
        try await pool.write { db in
            guard try RecordRow.exists(id: id, db: db) else { throw CCStoreError.notFound(id) }
            guard try String.fetchOne(db, sql: "SELECT target_id FROM index_generation_pointer WHERE id=1") == nil else {
                throw CCStoreError.invalidGeneration("versioned commit required")
            }
            try db.execute(
                sql: """
                INSERT INTO embeddings (record_id, dim, vector, input_version)
                SELECT ?, ?, ?, version FROM record_input_versions WHERE record_id = ?
                ON CONFLICT(record_id) DO UPDATE SET dim = excluded.dim, vector = excluded.vector, input_version = excluded.input_version
                """,
                arguments: [id, dim, blob, id]
            )
        }
    }

    /// 全埋め込みとの内積（ベクトルは L2 正規化済みなのでコサイン類似度）を vDSP で計算し、上位 `limit` 件を返す。
    /// 状態（archived 等）では絞らない（絞るなら `search(vector:limit:statuses:)`）。同点は id の新しい順。
    public func search(vector: [Float], limit: Int) async throws -> [SearchHit] {
        try await search(vector: vector, limit: limit, statuses: [])
    }

    /// `statuses` の状態のレコードだけを対象に、上位 `limit` 件を返す。空集合なら全状態（`InboxFilter.statuses` と同じ）。
    /// 状態での絞り込みは上位を選ぶ**前**に効くので、archived が多くても `limit` 件まで埋まる。同点は id の新しい順。
    public func search(vector: [Float], limit: Int, statuses: Set<RecordStatus>) async throws -> [SearchHit] {
        try await searchSnapshot(vector: vector, limit: limit, statuses: statuses, compatibilityKey: nil)
    }

    public func search(vector: [Float], limit: Int, statuses: Set<RecordStatus>, compatibilityKey: String) async throws -> [SearchHit] {
        try await searchSnapshot(vector: vector, limit: limit, statuses: statuses, compatibilityKey: compatibilityKey)
    }

    private func searchSnapshot(vector: [Float], limit: Int, statuses: Set<RecordStatus>, compatibilityKey: String?) async throws -> [SearchHit] {
        guard vector.count == dimension else {
            throw CCStoreError.dimensionMismatch(expected: dimension, actual: vector.count)
        }
        guard limit > 0 else { return [] }
        let dim = dimension
        let cache = embeddingCache
        let statusValues = statuses.map(\.rawValue).sorted()
        return try await pool.read { db in
            if let compatibilityKey {
                let active = try String.fetchOne(db, sql: "SELECT active_id FROM index_generation_pointer WHERE id=1")
                guard let generation = try Self.generation(active, db: db), generation.pipeline.compatibilityKey == compatibilityKey else {
                    throw CCStoreError.invalidGeneration("query/index compatibility mismatch")
                }
            }
            // 1. 全ベクトル（連続バッファ）。埋め込みが変わっていなければキャッシュを使う。
            let snapshot = try cache.snapshot(db: db, dimension: dim)
            let ids = snapshot.ids
            let n = ids.count
            guard n > 0 else { return [] }

            // 2. scores = matrix (n×dim) · vector (dim×1)
            var scores = [Float](repeating: 0, count: n)
            vDSP_mmul(snapshot.matrix, 1, vector, 1, &scores, 1, vDSP_Length(n), 1, vDSP_Length(dim))

            // 3. 状態で絞る（上位を選ぶ前）。
            var candidates: [Int]?
            if !statusValues.isEmpty {
                let allowed = try Set(String.fetchAll(
                    db,
                    sql: "SELECT id FROM records WHERE status IN (\(Self.placeholders(statusValues.count)))",
                    arguments: StatementArguments(statusValues)
                ))
                candidates = ids.indices.filter { allowed.contains(ids[$0]) }
            }

            // 4. 上位 k 件（k は小さい前提の挿入法）。
            let top = Self.topK(scores: scores, ids: ids, k: min(limit, candidates?.count ?? n), candidates: candidates)
            guard !top.isEmpty else { return [] }

            // 5. 該当レコードだけ読む。
            let topIDs = top.map { ids[$0] }
            let rowsByID = try Dictionary(
                uniqueKeysWithValues: Row.fetchAll(
                    db,
                    sql: "SELECT id, json FROM records WHERE id IN (\(Self.placeholders(topIDs.count)))",
                    arguments: StatementArguments(topIDs)
                ).map { row -> (String, ContextRecord) in (row["id"], try RecordRow.decode(row)) }
            )
            return top.compactMap { i in rowsByID[ids[i]].map { SearchHit(record: $0, score: scores[i]) } }
        }
    }

    /// 埋め込みを持たないレコードの id（SQL で引く。起動時のインデックス再開用）。
    /// 次元が `dimension` と違う（古い）埋め込みは「無い」とみなす（検索の対象にもならないので、作り直す対象）。
    public func idsWithoutEmbedding() async throws -> Set<String> {
        try await idsWithoutEmbedding(dimension: dimension)
    }

    /// 埋め込み（次元が `dimension` のもの）を持つレコードの id（SQL で引く）。
    public func idsWithEmbedding() async throws -> Set<String> {
        try await idsWithEmbedding(dimension: dimension)
    }

    /// スコア降順（同点は id 降順）の上位 k 件の添字。
    /// `candidates` を渡せばその添字だけから選ぶ（nil なら全件）。
    static func topK(scores: [Float], ids: [String], k: Int, candidates: [Int]? = nil) -> [Int] {
        guard k > 0 else { return [] }
        func better(_ a: Int, _ b: Int) -> Bool {
            scores[a] != scores[b] ? scores[a] > scores[b] : ids[a] > ids[b]
        }
        var top: [Int] = []
        top.reserveCapacity(k + 1)
        for i in candidates ?? Array(scores.indices) {
            if top.count == k, !better(i, top[k - 1]) { continue }
            var pos = top.count
            while pos > 0, better(i, top[pos - 1]) { pos -= 1 }
            top.insert(i, at: pos)
            if top.count > k { top.removeLast() }
        }
        return top
    }

    // MARK: - 添付

    public func writeAttachment(_ data: Data, id: String, kind: AttachmentKind, ext: String, capturedAt: Date) async throws -> String {
        let relative = CCPaths.attachmentRelativePath(id: id, kind: kind, ext: ext, capturedAt: capturedAt, timeZone: timeZone)
        let url = try paths.url(forRelativePath: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if kind == .screenshot {
            // Once a record refers to a raw screenshot, its path is an immutable input identity.
            // Serialize the reference check and atomic write with record insert/update.
            try await pool.write { db in
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM records WHERE screenshot_path=?)", arguments: [relative]) == true {
                    throw CCStoreError.immutableAttachment
                }
                try data.write(to: url, options: .atomic)
            }
        } else { try data.write(to: url, options: .atomic) }
        return relative
    }

    public func attachmentURL(for relativePath: String) async throws -> URL {
        try paths.url(forRelativePath: relativePath)
    }

    /// 相対パスのファイルを消す。無いファイル・不正なパスは無視する。
    func removeFiles(_ relativePaths: [String]) {
        for rel in relativePaths {
            guard let url = try? paths.url(forRelativePath: rel) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// レコードに記録されていない添付（書き込み後、レコード更新前に落ちた等）も消す。
    /// 撮影日のディレクトリにある `<id>.*` と `<id>-masked.*` が対象。
    private func removeStrayAttachments(id: String, capturedAt: Date) {
        let sample = CCPaths.attachmentRelativePath(id: id, kind: .screenshot, ext: "x", capturedAt: capturedAt, timeZone: timeZone)
        guard let dir = try? paths.url(forRelativePath: sample).deletingLastPathComponent(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return }
        let prefixes = AttachmentKind.allCases.map { id + $0.fileSuffix + "." }
        for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - 追記・状態更新（MCP 用。トランザクション内の read-modify-write）

    /// id のレコードを読み、`transform` で書き換えて保存する。1 つの IMMEDIATE トランザクション内で行うので、
    /// 別接続・別プロセスからの同時更新で変更が失われない。id が無ければ `CCStoreError.notFound`。
    /// `transform` で id を変えてはいけない（変えたら元の id のまま保存する）。
    @discardableResult
    public func modify(id: String, _ transform: @escaping @Sendable (inout ContextRecord) throws -> Void) async throws -> ContextRecord {
        try await pool.write { db in
            guard var record = try RecordRow.fetch(id: id, db: db) else { throw CCStoreError.notFound(id) }
            try transform(&record)
            record.id = id
            try RecordRow.update(record, db: db)
            return record
        }
    }

    /// 追記を末尾に足す（MCP `add_note`）。更新後のレコードを返す。
    @discardableResult
    public func appendNote(id: String, note: Note) async throws -> ContextRecord {
        try await modify(id: id) { $0.notes.append(note) }
    }

    /// 状態を変える（MCP `mark_done` / `archive`）。更新後のレコードを返す。
    @discardableResult
    public func setStatus(id: String, _ status: RecordStatus) async throws -> ContextRecord {
        try await modify(id: id) { $0.status = status }
    }

    /// 受け渡し履歴を末尾に足す。更新後のレコードを返す。
    @discardableResult
    public func appendHandoff(id: String, _ handoff: Handoff) async throws -> ContextRecord {
        try await modify(id: id) { $0.handoffs.append(handoff) }
    }

    // MARK: - 保持期間

    /// 撮影から `olderThan` 秒より古いレコードの音声ファイルを消し、`audioPath` を nil にする（文字起こしは残す）。
    /// 処理したレコード数を返す。
    @discardableResult
    public func purgeExpiredAudio(
        olderThan: TimeInterval = SQLiteRecordStore.defaultAudioRetention,
        now: Date = Date()
    ) async throws -> Int {
        try await purge(where: "audio_path IS NOT NULL", cutoff: now.addingTimeInterval(-olderThan)) { record in
            defer { record.audioPath = nil }
            return [record.audioPath].compactMap { $0 }
        }
    }

    /// 撮影から `retentionDays` 日（24 時間 × 日数）より古いレコードのスクショ（マスク版も）を消し、パスを nil にする。
    /// `retentionDays` が nil なら無期限保持で何もしない。処理したレコード数を返す。
    ///
    /// ガードの判定（`guardInfo`）も「画像なし」にする（`.clear`・検出箇所なし）。判定の対象の画像が無くなったので、
    /// `needs_review` のまま Inbox の要確認に残したり、マスク待ちのままにしたりしない（MCP は「スクショがありません」を返す）。
    /// 受け渡しの履歴（`handoffs`）など他のフィールドは残す。
    @discardableResult
    public func purgeExpiredScreenshots(retentionDays: Int?, now: Date = Date()) async throws -> Int {
        guard let retentionDays else { return 0 }
        return try await purge(
            where: "screenshot_path IS NOT NULL OR masked_screenshot_path IS NOT NULL",
            cutoff: now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 60 * 60)
        ) { record in
            defer {
                record.screenshotPath = nil
                record.maskedScreenshotPath = nil
                record.guardInfo = GuardInfo(status: .clear, findings: [])
            }
            return [record.screenshotPath, record.maskedScreenshotPath].compactMap { $0 }
        }
    }

    /// `(<condition>) AND captured_at < cutoff` の各レコードを `strip` で書き換えて保存し、
    /// コミット後に `strip` が返したファイルを消す。書き換えたレコード数を返す。
    private func purge(
        where condition: String,
        cutoff: Date,
        strip: @escaping @Sendable (inout ContextRecord) -> [String]
    ) async throws -> Int {
        let (count, files): (Int, [String]) = try await pool.write { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM records WHERE (\(condition)) AND captured_at < ?",
                arguments: [cutoff.timeIntervalSince1970]
            )
            var files: [String] = []
            var count = 0
            for id in ids {
                guard var record = try RecordRow.fetch(id: id, db: db) else { continue }
                files += strip(&record)
                try RecordRow.update(record, db: db)
                count += 1
            }
            return (count, files)
        }
        removeFiles(files)
        return count
    }
}

// MARK: - CCCore の追加プロトコルへの準拠

extension SQLiteRecordStore: RecordModifying, EmbeddingPresenceChecking, StatusFilteredSearching, GenerationFilteredSearching {
    /// 次元が `dimension` の埋め込みを持つレコードの id。SQL で引く（零ベクトルの全件検索は使わない）。
    public func idsWithEmbedding(dimension: Int) async throws -> Set<String> {
        try await pool.read { db in
            try Set(String.fetchAll(
                db,
                sql: Self.presenceSQL(db: db),
                arguments: [dimension]
            ))
        }
    }

    /// 次元が `dimension` の埋め込みを持たないレコードの id（違う次元の古い埋め込みしか無いものを含む）。SQL で引く。
    public func idsWithoutEmbedding(dimension: Int) async throws -> Set<String> {
        try await pool.read { db in
            let present = try Set(String.fetchAll(db, sql: Self.presenceSQL(db: db), arguments: [dimension]))
            let all = try Set(String.fetchAll(db, sql: "SELECT id FROM records"))
            return all.subtracting(present)
        }
    }

    static func presenceSQL(db: Database) throws -> String {
        if let id = try String.fetchOne(db, sql: "SELECT coalesce(target_id,active_id) FROM index_generation_pointer WHERE id=1") {
            // UUIDs are generated internally, but bind the value with quote() instead of interpolating it unescaped.
            let quoted = try String.fetchOne(db, sql: "SELECT quote(?)", arguments: [id])!
            return "SELECT e.record_id FROM generation_embeddings e JOIN record_input_versions i ON i.record_id=e.record_id AND i.version=e.input_version WHERE e.generation_id=\(quoted) AND e.dim=?"
        }
        return "SELECT e.record_id FROM embeddings e JOIN record_input_versions i ON i.record_id=e.record_id AND i.version=e.input_version WHERE e.dim=?"
    }
}
