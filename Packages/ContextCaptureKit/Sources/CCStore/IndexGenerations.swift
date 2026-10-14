import CCCore
import Foundation
import GRDB

extension SQLiteRecordStore: IndexGenerationManaging {
    static func generation(_ id: String?, db: Database) throws -> IndexGeneration? {
        guard let id, let row = try Row.fetchOne(db, sql: "SELECT id,pipeline_json,state FROM index_generations WHERE id=?", arguments: [id]) else { return nil }
        let json: String = row["pipeline_json"]
        return IndexGeneration(id: row["id"], pipeline: try JSONDecoder().decode(EmbeddingPipeline.self, from: Data(json.utf8)), state: row["state"])
    }
    public func activeGeneration() async throws -> IndexGeneration? {
        try await pool.read { db in try Self.generation(String.fetchOne(db, sql: "SELECT active_id FROM index_generation_pointer WHERE id=1"), db: db) }
    }
    public func targetGeneration() async throws -> IndexGeneration? {
        try await pool.read { db in try Self.generation(String.fetchOne(db, sql: "SELECT target_id FROM index_generation_pointer WHERE id=1"), db: db) }
    }
    public func beginGeneration(_ pipeline: EmbeddingPipeline) async throws -> IndexGeneration {
        guard pipeline.dimension == dimension, pipeline.vectorSchemaVersion == 1,
              !pipeline.modelID.isEmpty, !pipeline.revision.isEmpty else { throw CCStoreError.invalidGeneration("unsupported pipeline") }
        let key = pipeline.compatibilityKey
        let json = String(decoding: try JSONEncoder().encode(pipeline), as: UTF8.self)
        return try await pool.write { db in
            let existing = try String.fetchOne(db, sql: "SELECT id FROM index_generations WHERE compatibility_key=?", arguments: [key])
            let id = existing ?? UUID().uuidString
            if existing == nil {
                try db.execute(sql: "INSERT INTO index_generations(id,compatibility_key,pipeline_json) VALUES(?,?,?)", arguments: [id,key,json])
            }
            try db.execute(sql: "UPDATE index_generation_pointer SET target_id=? WHERE id=1", arguments: [id])
            try db.execute(sql: """
                INSERT INTO generation_jobs(record_id,generation_id,input_version,state)
                SELECT i.record_id,?,i.version,'pending' FROM record_input_versions i
                LEFT JOIN generation_embeddings e ON e.record_id=i.record_id AND e.generation_id=? AND e.input_version=i.version
                WHERE e.record_id IS NULL
                ON CONFLICT(record_id,generation_id) DO UPDATE SET input_version=excluded.input_version,state='pending'
                """, arguments: [id,id])
            return try Self.generation(id, db: db)!
        }
    }
    public func embeddingInput(id: String) async throws -> EmbeddingInput? {
        try await pool.read { db in
            guard let record = try RecordRow.fetch(id: id, db: db),
                  let version = try Int64.fetchOne(db, sql: "SELECT version FROM record_input_versions WHERE record_id=?", arguments: [id]) else { return nil }
            let generation = try String.fetchOne(db, sql: "SELECT target_id FROM index_generation_pointer WHERE id=1")
            return EmbeddingInput(record: record, version: version, generationID: generation)
        }
    }
    public func commitEmbedding(_ embedding: SignedEmbedding, input: EmbeddingInput) async throws -> Bool {
        let vector = embedding.vector
        guard vector.count == dimension else { throw CCStoreError.dimensionMismatch(expected: dimension, actual: vector.count) }
        guard vector.allSatisfy(\.isFinite) else { throw CCStoreError.invalidVector }
        let blob = VectorCodec.encode(vector), dim = dimension
        return try await pool.write { db in
            guard let current = try RecordRow.fetch(id: input.record.id, db: db),
                  let version = try Int64.fetchOne(db, sql: "SELECT version FROM record_input_versions WHERE record_id=?", arguments: [input.record.id]),
                  version == input.version,
                  current.annotation.text == input.record.annotation.text,
                  current.window?.title == input.record.window?.title,
                  current.screenshotPath == input.record.screenshotPath else { return false }
            guard let id = input.generationID else {
                guard try String.fetchOne(db, sql: "SELECT target_id FROM index_generation_pointer WHERE id=1") == nil else { return false }
                // Legacy callers before activation. Version is still guarded in this transaction.
                try db.execute(sql: "INSERT INTO embeddings(record_id,dim,vector,input_version) VALUES(?,?,?,?) ON CONFLICT(record_id) DO UPDATE SET dim=excluded.dim,vector=excluded.vector,input_version=excluded.input_version", arguments: [current.id,dim,blob,version])
                return true
            }
            guard let generation = try Self.generation(id, db: db), generation.pipeline.compatibilityKey == embedding.compatibilityKey else { return false }
            try db.execute(sql: """
                INSERT INTO generation_embeddings(record_id,generation_id,input_version,input_hash,dim,vector) VALUES(?,?,?,?,?,?)
                ON CONFLICT(record_id,generation_id) DO UPDATE SET input_version=excluded.input_version,input_hash=excluded.input_hash,dim=excluded.dim,vector=excluded.vector
                """, arguments: [current.id,id,version,input.hash,dim,blob])
            try db.execute(sql: "UPDATE generation_jobs SET state='succeeded',attempts=attempts+1 WHERE record_id=? AND generation_id=? AND input_version=?", arguments: [current.id,id,version])
            return true
        }
    }
    public func missingGenerationIDs(_ id: String, limit: Int) async throws -> [String] {
        guard limit > 0 else { return [] }
        return try await pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT r.id FROM records r JOIN record_input_versions i ON i.record_id=r.id
                LEFT JOIN generation_embeddings e ON e.record_id=r.id AND e.generation_id=? AND e.input_version=i.version
                WHERE e.record_id IS NULL ORDER BY r.captured_at DESC,r.id DESC LIMIT ?
                """, arguments: [id,limit])
        }
    }
    public func activateGeneration(_ id: String) async throws -> Bool {
        try await pool.write { db in
            guard try Self.generation(id, db: db) != nil,
                  try String.fetchOne(db, sql: "SELECT target_id FROM index_generation_pointer WHERE id=1") == id,
                  try Self.isComplete(id, db: db) else { return false }
            try db.execute(sql: "UPDATE index_generations SET state='ready' WHERE id=?", arguments: [id])
            try db.execute(sql: "UPDATE index_generation_pointer SET active_id=? WHERE id=1", arguments: [id])
            return true
        }
    }
    /// Rollback succeeds only if the old generation is up to date; otherwise keyword fallback/rebuild is required.
    public func rollbackGeneration(_ id: String) async throws -> Bool {
        try await pool.write { db in
            guard let old = try Self.generation(id, db: db), old.state == "ready", try Self.isComplete(id, db: db) else { return false }
            try db.execute(sql: "UPDATE index_generation_pointer SET active_id=?,target_id=? WHERE id=1", arguments: [id,id])
            return true
        }
    }
    static func isComplete(_ id: String, db: Database) throws -> Bool {
        try !Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM record_input_versions i LEFT JOIN generation_embeddings e
                ON e.record_id=i.record_id AND e.generation_id=? AND e.input_version=i.version WHERE e.record_id IS NULL)
            """, arguments: [id])!
    }
}
