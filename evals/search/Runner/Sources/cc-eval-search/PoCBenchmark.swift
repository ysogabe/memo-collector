import CCCore
import CCStore
import Foundation
import SearchEvaluation
import SearchPoC

func evaluatePoC(corpus: Corpus, queries: [QueryFixture], cache: VectorCache, store: SQLiteRecordStore,
                 root: URL, repeats: Int, depth: Int) async throws -> ([String: ModeReport], [String: String]) {
    let file = root.appendingPathComponent("keyword.sqlite")
    let start = now()
    let index = try KeywordIndex(records: corpus.records.map(\.record), file: file)
    let indexMs = elapsed(start)
    var semantic: [String: [RankedItem]] = [:], keyword: [String: [RankedItem]] = [:]
    var evidence: [String: [String: [Evidence]]] = [:]
    for q in queries {
        let statuses: Set<RecordStatus> = q.includeArchived ? [] : [.inbox, .done]
        semantic[q.id] = try await store.search(vector: cache.queries[q.id]!, limit: 50, statuses: statuses).map { RankedItem(recordID: $0.record.id, score: Double($0.score)) }
        let hits = try index.search(q.text, includeArchived: q.includeArchived, trigram: true, limit: 50)
        keyword[q.id] = hits.map { RankedItem(recordID: $0.recordID, score: $0.score) }
        evidence[q.id] = Dictionary(uniqueKeysWithValues: hits.map { ($0.recordID, $0.evidence) })
    }
    // Only dev labels select the threshold. Holdout is evaluated once with this frozen value.
    let grid = stride(from: 0.20, through: 0.80, by: 0.05).map { $0 }
    var threshold = grid[0], best = -Double.infinity
    var tuning: [String: String] = [:]
    for t in grid {
        let rows = queries.filter { $0.split == "dev" }.map { q -> QueryResult in
            let gated = Fusion.gate(semantic[q.id]!, threshold: t, exactLookup: SearchText.exactLookup(q.text))
            let ranked = Fusion.rrf([gated, keyword[q.id]!], limit: depth)
            return QueryResult(query: q, items: ranked, milliseconds: [])
        }
        let summary = Summary.aggregate(rows)
        let utility = 0.45 * (summary.recall["3"] ?? 0) + 0.35 * (summary.mrr ?? 0) + 0.20 * (summary.noAnswerEmptyRate ?? 0)
        tuning[String(format: "%.2f", t)] = String(utility)
        if utility > best + 1e-12 { best = utility; threshold = t }
    }
    var reports: [String: ModeReport] = [:]
    for mode in ["baseline_native_vector", "poc_unicode61", "poc_trigram_short_exact", "poc_rrf", "poc_gated_rrf"] {
        var results: [QueryResult] = []
        for q in queries {
            var times: [Double] = [], items: [RankedItem] = []
            for _ in 0..<repeats {
                let start = now()
                let lexical = mode == "baseline_native_vector" ? [] : try index.search(q.text, includeArchived: q.includeArchived, trigram: mode != "poc_unicode61", limit: 50).map { RankedItem(recordID: $0.recordID, score: $0.score) }
                if mode == "baseline_native_vector" {
                    let statuses: Set<RecordStatus> = q.includeArchived ? [] : [.inbox, .done]
                    items = try await store.search(vector: cache.queries[q.id]!, limit: depth, statuses: statuses).map { RankedItem(recordID: $0.record.id, score: Double($0.score)) }
                } else if mode == "poc_rrf" || mode == "poc_gated_rrf" {
                    let statuses: Set<RecordStatus> = q.includeArchived ? [] : [.inbox, .done]
                    let vector = try await store.search(vector: cache.queries[q.id]!, limit: 50, statuses: statuses).map { RankedItem(recordID: $0.record.id, score: Double($0.score)) }
                    let selected = mode == "poc_gated_rrf" ? Fusion.gate(vector, threshold: threshold, exactLookup: SearchText.exactLookup(q.text)) : vector
                    items = Fusion.rrf([selected, lexical], limit: depth)
                } else { items = Array(lexical.prefix(depth)) }
                times.append(elapsed(start))
            }
            results.append(QueryResult(query: q, items: items, milliseconds: times))
        }
        reports[mode] = ModeReport(summaries: summaries(results), results: results, evidence: evidence,
                                  configuration: ["latency_scope": "retrieval only, fixed CoreML query vectors; excludes query inference",
                                                  "rrf_k": "60", "candidates_per_source": "50", "threshold": mode == "poc_gated_rrf" ? String(threshold) : "none",
                                                  "exact_lookup": mode == "poc_gated_rrf" ? "keyword-only for URL, #number and single ASCII identifier" : "independent semantic and keyword",
                                                  "tuning_split": "dev only", "dev_utility": "0.45 Recall@3 + 0.35 MRR + 0.20 no-answer-empty-rate"])
    }
    let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
    var metadata = ["poc_sqlite_version": index.sqliteVersion, "poc_index_milliseconds": String(indexMs),
                      "poc_database_bytes": bytes.map(String.init) ?? "unknown", "poc_threshold": String(threshold),
                      "poc_tuning_grid": tuning.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }.joined(separator: ","),
                      "poc_limits": "48-record synthetic text-only set; no new product index; no raw OCR persisted"]
    metadata.merge(try measureKeywordCapacity(corpus: corpus, queries: queries, root: root)) { _, new in new }
    return (reports, metadata)
}

/// Capacity measurement on repeated synthetic text, separate from the 48-record quality corpus.
func measureKeywordCapacity(corpus: Corpus, queries: [QueryFixture], root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for count in [1_000, 10_000] {
        let records = (0..<count).map { i -> ContextRecord in
            var r = corpus.records[i % corpus.records.count].record
            r.id = ULID.generate(now: Date(timeIntervalSince1970: Double(i))).string
            return r
        }
        let file = root.appendingPathComponent("keyword-capacity-\(count).sqlite")
        let start = now(); let index = try KeywordIndex(records: records, file: file)
        result["poc_capacity_\(count)_index_ms"] = String(elapsed(start))
        var times: [Double] = []
        for q in queries.prefix(10) {
            _ = try index.search(q.text, includeArchived: q.includeArchived, trigram: true, limit: 30)
            for _ in 0..<3 {
                let start = now(); _ = try index.search(q.text, includeArchived: q.includeArchived, trigram: true, limit: 30)
                times.append(elapsed(start))
            }
        }
        result["poc_capacity_\(count)_p50_ms"] = String(Metrics.percentile(times, 0.5)!)
        result["poc_capacity_\(count)_p95_ms"] = String(Metrics.percentile(times, 0.95)!)
        let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).int64Value
        result["poc_capacity_\(count)_bytes"] = String(bytes)
    }
    result["poc_capacity_scope"] = "repeated authored synthetic text; keyword retrieval only; shared projection + BOTH word/trigram FTS indexes; no quality claims"
    return result
}
