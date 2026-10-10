import CCCore
import Foundation
import GRDB
import XCTest
@testable import CCStore

/// 1 万件の全件検索。目標は 50ms 以内（PRD / 計画）。テストの閾値はマシン差・デバッグビルドを考えて緩めにする。
final class SearchBenchmarkTests: XCTestCase {
    func testSearch10kUnderBudget() async throws {
        let root = try TempDataRoot()
        let store = try root.makeStore()
        let n = 10_000
        let dim = store.dimension

        var rng = SplitMix64(seed: 42)
        func randomUnit() -> [Float] {
            var v = (0..<dim).map { _ in Float.random(in: -1...1, using: &rng) }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            for i in v.indices { v[i] /= norm }
            return v
        }

        let target = unitVector([7: 1], dim: dim)
        var targetID = ""
        // 準備は 1 トランザクションでまとめて入れる（1 件ずつだと準備だけで数秒かかる）。
        var records: [(ContextRecord, [Float])] = []
        for i in 0..<n {
            let r = makeRecord(at: TimeInterval(i))
            records.append((r, i == n / 2 ? target : randomUnit()))
            if i == n / 2 { targetID = r.id }
        }
        try await store.pool.write { [records] db in
            for (r, v) in records {
                try RecordRow.insert(r, db: db)
                try db.execute(
                    sql: "INSERT INTO embeddings (record_id, dim, vector) VALUES (?, ?, ?)",
                    arguments: [r.id, dim, VectorCodec.encode(v)]
                )
            }
        }

        // 初回（行列キャッシュが空 = DB から全ベクトルを読む）
        let c0 = DispatchTime.now().uptimeNanoseconds
        _ = try await store.search(vector: target, limit: 10)
        let cold = Double(DispatchTime.now().uptimeNanoseconds - c0) / 1e6
        print("[CCStore bench] search 10k cold (load matrix): \(String(format: "%.1f", cold)) ms")
        var timings: [Double] = []
        var hits: [SearchHit] = []
        for _ in 0..<5 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            hits = try await store.search(vector: target, limit: 10)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        let median = timings.sorted()[timings.count / 2]
        print("[CCStore bench] search 10k x \(dim)d limit 10 warm: median \(String(format: "%.1f", median)) ms, all \(timings.map { String(format: "%.1f", $0) })")

        XCTAssertEqual(hits.count, 10)
        XCTAssertEqual(hits.first?.record.id, targetID)
        XCTAssertEqual(hits.first?.score ?? 0, 1, accuracy: 1e-4)
        XCTAssertTrue(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
        XCTAssertLessThan(median, 500, "目標 50ms（キャッシュ有効時）。デバッグビルド・並行ビルド中の高負荷を見込んで 500ms で落とす")
        XCTAssertLessThan(cold, 3000, "初回は全ベクトルの読み込みを含む")
    }
}

/// 再現可能な乱数。
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
