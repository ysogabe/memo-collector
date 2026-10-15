import CCCore
import Darwin
import Foundation
import GRDB
import SQLite3

/// Maintenance-only inspection. No migrations, directory creation, models, or attachments.
public struct IntentMaintenanceSnapshot: Sendable, Encodable {
    public var totalRecords = 0
    public var manualRecords = 0
    public var unprocessedRecords = 0
    public var fixtureRecords = 0
    public var emptyAnnotations = 0
    public var eligibleRecords = 0
    public var currentIntentCounts: [String: Int] = [:]
    public var storedProbabilitiesMissing = 0
    public var storedProbabilitiesInvalid = 0
    public var storedClassifiedAt70 = 0
    public var storedClassifiedAt60 = 0
    public var storedClassificationChanges70To60 = 0
    /// Kept in memory for the queue; never encoded in a report.
    public var eligibleIDs: [String] = []

    enum CodingKeys: String, CodingKey {
        case totalRecords, manualRecords, unprocessedRecords, fixtureRecords, emptyAnnotations, eligibleRecords
        case currentIntentCounts, storedProbabilitiesMissing, storedProbabilitiesInvalid
        case storedClassifiedAt70, storedClassifiedAt60, storedClassificationChanges70To60
    }
}

public enum IntentMaintenanceError: Error {
    case invalidDatabase, invalidDestination, destinationExists, backupInvalid, forbiddenOperation
}

/// Existing, fixed-name database only. Errors deliberately carry no record text, URLs, or IDs.
public enum IntentMaintenance {
    static func existingDatabase(_ paths: CCPaths) throws -> URL {
        let url = paths.databaseURL.standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard url.lastPathComponent == CCPaths.databaseFileName,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw IntentMaintenanceError.invalidDatabase }
        return url
    }

    static func readOnlyQueue(_ paths: CCPaths) throws -> DatabaseQueue {
        let url = try existingDatabase(paths)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(10)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok",
                  Set(try db.columns(in: "records").map(\.name)).isSuperset(of: ["id", "captured_at", "intent", "has_triage", "json"])
            else { throw IntentMaintenanceError.invalidDatabase }
        }
        return queue
    }

    /// Product text preprocessing belongs to CCTriage/its caller, not the persistence layer.
    /// The default performs only the store's raw-whitespace preflight.
    public static func preview(
        paths: CCPaths,
        isAnnotationEmpty: @escaping @Sendable (String) -> Bool = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    ) throws -> IntentMaintenanceSnapshot {
        let queue = try readOnlyQueue(paths)
        defer { try? queue.close() }
        return try queue.read { db in
            var result = IntentMaintenanceSnapshot()
            for row in try Row.fetchAll(db, sql: "SELECT id, json FROM records ORDER BY captured_at, id") {
                let record = try RecordRow.decode(row)
                result.totalRecords += 1
                if record.extra["dev_fixture"] == "true" { result.fixtureRecords += 1; continue }
                result.currentIntentCounts[record.triage?.intent?.rawValue ?? "unclassified", default: 0] += 1
                if record.triage?.model == "user" { result.manualRecords += 1; continue }
                guard let triage = record.triage else { result.unprocessedRecords += 1; continue }
                guard !isAnnotationEmpty(record.annotation.text) else { result.emptyAnnotations += 1; continue }
                result.eligibleIDs.append(record.id)
                result.eligibleRecords += 1
                guard let p = triage.intentProbabilities else { result.storedProbabilitiesMissing += 1; continue }
                guard Set(p.keys) == Set(Intent.allCases), p.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                      abs(p.values.reduce(0, +) - 1) <= 0.001 else { result.storedProbabilitiesInvalid += 1; continue }
                let old = resolveIntent(probabilities: p, threshold: 0.7).intent
                let adopted = resolveIntent(probabilities: p, threshold: 0.6).intent
                if old != nil { result.storedClassifiedAt70 += 1 }
                if adopted != nil { result.storedClassifiedAt60 += 1 }
                if old != adopted { result.storedClassificationChanges70To60 += 1 }
            }
            return result
        }
    }

    /// Refuse application roots, aliases of protected files, existing files, and missing parent directories.
    public static func validateDestination(_ destination: URL, paths: CCPaths, protected: [URL] = []) throws {
        let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
        let defaults = CCPaths.resolve(environment: [:])
        let environment = CCPaths.resolve()
        let roots = [paths.dataRoot, paths.modelsRoot, defaults.dataRoot, defaults.modelsRoot, environment.dataRoot, environment.modelsRoot]
        guard !roots.contains(where: { root in
            let path = root.standardizedFileURL.resolvingSymlinksInPath().path
            return resolved.path == path || resolved.path.hasPrefix(path.hasSuffix("/") ? path : path + "/")
        }), !([paths.databaseURL] + protected).contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == resolved }),
              (try? FileManager.default.attributesOfItem(atPath: resolved.deletingLastPathComponent().path)[.type]) as? FileAttributeType == .typeDirectory
        else { throw IntentMaintenanceError.invalidDestination }
        // Includes dangling symbolic links, which fileExists alone would miss.
        if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil { throw IntentMaintenanceError.destinationExists }
    }

    /// O_EXCL prevents replacement (including symlinks); permission is private from the first byte.
    static func reservePrivateFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw IntentMaintenanceError.destinationExists }
        Darwin.close(descriptor)
    }

    /// SQLite's backup API includes committed WAL contents. Never copy only the main .sqlite file.
    public static func backup(paths: CCPaths, to destination: URL) throws {
        try validateDestination(destination, paths: paths)
        let source = try readOnlyQueue(paths)
        defer { try? source.close() }
        try reservePrivateFile(destination)
        do {
            let target = try DatabaseQueue(path: destination.path)
            do {
                try source.backup(to: target)
                try target.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode=DELETE") }
                let valid = try target.read { db in
                    try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" && db.tableExists("records")
                }
                guard valid else { throw IntentMaintenanceError.backupInvalid }
                try target.close()
            } catch { try? target.close(); throw error }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public static func writeReport(_ data: Data, to destination: URL, paths: CCPaths, protected: [URL] = []) throws {
        try validateDestination(destination, paths: paths, protected: protected)
        try reservePrivateFile(destination)
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}

/// Restricted adapter for TriageQueue.reprocess(..., steps: [.intent]). No schema or index writes.
/// Unsupported protocol methods throw so an accidental non-intent job cannot touch attachments/vectors.
public final class IntentOnlyRecordStore: RecordStore, RecordModifying, EmbeddingPresenceChecking, @unchecked Sendable {
    private let queue: DatabaseQueue
    /// Access to this connection and counters is serialized by lock. READWRITE omits CREATE.
    private let connection: OpaquePointer
    private let lock = NSLock()
    private var changed = 0
    private var classificationChanged = 0
    public var changedResults: Int { lock.withLock { changed } }
    public var changedClassifications: Int { lock.withLock { classificationChanged } }

    /// Caller must complete an integrity-checked backup before constructing this writable adapter.
    public init(paths: CCPaths) throws {
        let verified = try IntentMaintenance.readOnlyQueue(paths)
        try verified.close()
        var handle: OpaquePointer?
        guard sqlite3_open_v2(paths.databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = handle else {
            if let handle { sqlite3_close(handle) }
            throw IntentMaintenanceError.invalidDatabase
        }
        connection = opened
        sqlite3_busy_timeout(opened, 10_000)
        do { queue = try IntentMaintenance.readOnlyQueue(paths) }
        catch { sqlite3_close(opened); throw error }
    }

    deinit { sqlite3_close(connection) }

    public func get(id: String) async throws -> ContextRecord? {
        try await queue.read { db in try RecordRow.fetch(id: id, db: db) }
    }

    @discardableResult
    public func modify(id: String, _ transform: @escaping @Sendable (inout ContextRecord) throws -> Void) async throws -> ContextRecord {
        return try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                guard let original = try fetchForUpdate(id) else { throw IntentMaintenanceError.forbiddenOperation }
                var updated = original
                try transform(&updated)
                let triage = updated.triage
                updated.triage = original.triage
                guard updated == original, original.triage?.model != "user", original.triage != nil,
                      original.extra["dev_fixture"] != "true", !original.annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      triage != nil else { throw IntentMaintenanceError.forbiddenOperation }
                updated.triage = triage
                // Change only triage in the original JSON, including unknown application fields.
                let json = String(decoding: try CCJSON.encoder().encode(triage), as: UTF8.self)
                try execute("UPDATE records SET intent = ?, has_triage = 1, json = json_set(json, '$.triage', json(?)) WHERE id = ?",
                            arguments: [triage?.intent?.rawValue, json, id])
                try execute("COMMIT")
                if original.triage != triage { changed += 1 }
                if original.triage?.intent != triage?.intent { classificationChanged += 1 }
                return updated
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    private func statement(_ sql: String, arguments: [String?] = []) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw IntentMaintenanceError.invalidDatabase
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            let code: Int32
            if let argument { code = sqlite3_bind_text(prepared, Int32(index + 1), argument, -1, transient) }
            else { code = sqlite3_bind_null(prepared, Int32(index + 1)) }
            guard code == SQLITE_OK else { sqlite3_finalize(prepared); throw IntentMaintenanceError.invalidDatabase }
        }
        return prepared
    }

    private func execute(_ sql: String, arguments: [String?] = []) throws {
        let prepared = try statement(sql, arguments: arguments)
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_step(prepared) == SQLITE_DONE else { throw IntentMaintenanceError.invalidDatabase }
    }

    private func fetchForUpdate(_ id: String) throws -> ContextRecord? {
        let prepared = try statement("SELECT json FROM records WHERE id = ?", arguments: [id])
        defer { sqlite3_finalize(prepared) }
        let code = sqlite3_step(prepared)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let value = sqlite3_column_text(prepared, 0) else { throw IntentMaintenanceError.invalidDatabase }
        return try CCJSON.decoder().decode(ContextRecord.self, from: Data(String(cString: value).utf8))
    }

    public func insert(_ record: ContextRecord) async throws { throw IntentMaintenanceError.forbiddenOperation }
    public func update(_ record: ContextRecord) async throws { throw IntentMaintenanceError.forbiddenOperation }
    public func delete(id: String) async throws { throw IntentMaintenanceError.forbiddenOperation }
    public func list(_ filter: InboxFilter) async throws -> [ContextRecord] { throw IntentMaintenanceError.forbiddenOperation }
    public func count(_ filter: InboxFilter) async throws -> Int { throw IntentMaintenanceError.forbiddenOperation }
    public func setEmbedding(id: String, vector: [Float]) async throws { throw IntentMaintenanceError.forbiddenOperation }
    public func search(vector: [Float], limit: Int) async throws -> [SearchHit] { throw IntentMaintenanceError.forbiddenOperation }
    public func idsWithEmbedding(dimension: Int) async throws -> Set<String> { throw IntentMaintenanceError.forbiddenOperation }
    public func idsWithoutEmbedding(dimension: Int) async throws -> Set<String> { throw IntentMaintenanceError.forbiddenOperation }
    public func writeAttachment(_ data: Data, id: String, kind: AttachmentKind, ext: String, capturedAt: Date) async throws -> String { throw IntentMaintenanceError.forbiddenOperation }
    public func attachmentURL(for relativePath: String) async throws -> URL { throw IntentMaintenanceError.forbiddenOperation }
}
