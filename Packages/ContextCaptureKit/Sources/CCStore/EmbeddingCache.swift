import Foundation
import GRDB

/// 全埋め込みを 1 本の連続した Float 行列（n × dim、行優先）にしたもの。
struct EmbeddingSnapshot: Sendable {
    let version: Int64
    let dimension: Int
    let ids: [String]
    let matrix: [Float]
}

/// 検索用の行列キャッシュ。`embeddings_version`（トリガで更新される世代番号）が変わったときだけ DB から読み直す。
/// 世代番号と行列は同じ読み取りトランザクション内で読むので、スナップショットは常に一貫している。
/// 1 万件 × 256 次元で約 10MB。
final class EmbeddingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: EmbeddingSnapshot?

    func snapshot(db: Database, dimension: Int) throws -> EmbeddingSnapshot {
        let version = try Int64.fetchOne(db, sql: "SELECT version FROM embeddings_version WHERE id = 1") ?? 0
        if let hit = lock.withLock({ cached }), hit.version == version, hit.dimension == dimension {
            return hit
        }
        var ids: [String] = []
        var matrix: [Float] = []
        let active = try String.fetchOne(db, sql: "SELECT active_id FROM index_generation_pointer WHERE id=1")
        let sql: String
        let arguments: StatementArguments
        if let active {
            sql = "SELECT e.record_id,e.vector FROM generation_embeddings e JOIN record_input_versions i ON i.record_id=e.record_id AND i.version=e.input_version WHERE e.generation_id=? AND e.dim=?"
            arguments = [active,dimension]
        } else {
            sql = "SELECT e.record_id,e.vector FROM embeddings e JOIN record_input_versions i ON i.record_id=e.record_id AND i.version=e.input_version WHERE e.dim=?"
            arguments = [dimension]
        }
        let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try rows.next() {
            let blob: Data = row["vector"]
            guard let v = VectorCodec.decode(blob, count: dimension) else { continue }
            ids.append(row["record_id"])
            matrix.append(contentsOf: v)
        }
        let fresh = EmbeddingSnapshot(version: version, dimension: dimension, ids: ids, matrix: matrix)
        lock.withLock {
            if (cached?.version ?? .min) <= version { cached = fresh }
        }
        return fresh
    }
}
