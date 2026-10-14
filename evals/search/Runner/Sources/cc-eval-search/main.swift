import CCCore
import CCStore
import CCEmbedding
import CCMCP
import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import SearchEvaluation
import SearchPoC

struct Options {
    var values: [String: String] = [:]
    var refresh: Bool = false
    var liveQueries: Bool = false
    var poc: Bool = false
    init() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--refresh" { refresh = true; continue }
            if key == "--live-queries" { liveQueries = true; continue }
            if key == "--poc" { poc = true; continue }
            guard ["--fixtures", "--models", "--cache", "--output", "--repeats", "--depth", "--compute"].contains(key), !args.isEmpty else {
                throw EvaluationError.invalid("usage: cc-eval-search --fixtures PATH --cache PATH --output PATH [--models MODEL_ROOT] [--refresh] [--live-queries] [--compute cpuAndGPU|cpuAndNeuralEngine] [--repeats 3] [--depth 30]")
            }
            values[key] = args.removeFirst()
        }
    }
    func required(_ key: String) throws -> String {
        guard let value = values[key] else { throw EvaluationError.invalid("missing \(key)") }
        return value
    }
    func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        let raw = values[key] ?? String(fallback)
        guard let n = Int(raw), range.contains(n) else { throw EvaluationError.invalid("invalid \(key)") }
        return n
    }
}
struct VectorCache: Codable {
    var corpusHash: String
    var queryHash: String
    var indexSignature: String
    var dimension: Int
    var computeUnits: String
    var documents: [String: [Float]]
    var queries: [String: [Float]]
    var documentMilliseconds: [String: Double]
    var queryMilliseconds: [String: Double]
    var preparationMilliseconds: Double
}
struct FrozenEmbedder: SignatureReportingEmbedder {
    let compatibilityKey: String
    let dimension: Int
    let vectors: [String: [Float]]
    func embedQuery(_ text: String) async throws -> [Float] {
        guard let vector = vectors[text] else { throw EvaluationError.invalid("query missing in cache") }
        return vector
    }
    func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] {
        throw EvaluationError.invalid("frozen query embedder has no document inference")
    }
    func embedQueryWithSignature(_ text: String) async throws -> SignedEmbedding {
        SignedEmbedding(vector: try await embedQuery(text), compatibilityKey: compatibilityKey)
    }
    func embedDocumentWithSignature(text: String, title: String?, image: CGImage?) async throws -> SignedEmbedding {
        throw EvaluationError.invalid("frozen query embedder has no document inference")
    }
}
struct ModeReport: Codable {
    var summaries: [String: Summary]
    var results: [QueryResult]
    var evidence: [String: [String: [Evidence]]]? = nil
    var configuration: [String: String]? = nil
}
struct Report: Codable {
    var schemaVersion = 1
    var corpusID: String
    var metadata: [String: String]
    var modes: [String: ModeReport]
}
struct MCPResultBody: Decodable {
    struct Item: Decodable { var id: String; var score: Double? }
    var mode: String
    var items: [Item]
}
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func elapsed(_ start: UInt64) -> Double { Double(now() - start) / 1_000_000 }
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try e.encode(value).write(to: url, options: .atomic)
}
func image(_ path: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(path as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw EvaluationError.invalid("unreadable fixture image \(path.path)") }
    return image
}
func summaries(_ results: [QueryResult]) -> [String: Summary] {
    var groups: [String: [QueryResult]] = ["ALL": results]
    for row in results {
        groups["split:\(row.split)", default: []].append(row)
        for tag in row.tags { groups["tag:\(tag)", default: []].append(row) }
    }
    return groups.mapValues(Summary.aggregate)
}
@main struct EvaluateSearch {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("cc-eval-search: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let o = try Options()
        let fixtureRoot = URL(fileURLWithPath: try o.required("--fixtures"))
        let cacheURL = URL(fileURLWithPath: try o.required("--cache"))
        let outputURL = URL(fileURLWithPath: try o.required("--output"))
        let repeats = try o.integer("--repeats", default: 3, range: 2...50)
        let depth = try o.integer("--depth", default: 30, range: 10...50)
        let corpusData = try Data(contentsOf: fixtureRoot.appendingPathComponent("records.json"))
        let queryData = try Data(contentsOf: fixtureRoot.appendingPathComponent("queries.json"))
        let corpus = try CCJSON.decoder().decode(Corpus.self, from: corpusData)
        let set = try JSONDecoder().decode(QuerySet.self, from: queryData)
        try set.validate(corpus: corpus)
        let modelsRoot = o.values["--models"].map { URL(fileURLWithPath: $0) } ?? CCPaths.resolve().modelsRoot
        guard let units = EmbeddingComputeUnits(rawValue: o.values["--compute"] ?? "cpuAndGPU") else { throw EvaluationError.invalid("unknown compute units") }
        let config = CoreMLEmbedder.Configuration(modelDirectory: modelsRoot.appendingPathComponent("embeddinggemma-2"), textComputeUnits: units, visionComputeUnits: units)
        var coreML: CoreMLEmbedder?
        let cache: VectorCache
        if FileManager.default.fileExists(atPath: cacheURL.path), !o.refresh {
            cache = try JSONDecoder().decode(VectorCache.self, from: Data(contentsOf: cacheURL))
            guard cache.corpusHash == digest(corpusData), cache.queryHash == digest(queryData), cache.indexSignature == config.indexSignature, cache.dimension == config.dimension else { throw EvaluationError.invalid("stale vector cache; use a new cache path or --refresh") }
        } else {
            let e = CoreMLEmbedder(configuration: config); coreML = e
            let start = now(); _ = try await e.prepare(includeVision: corpus.records.contains { $0.screen != nil })
            let prepareMs = elapsed(start)
            var docs: [String: [Float]] = [:], qs: [String: [Float]] = [:]
            var dm: [String: Double] = [:], qm: [String: Double] = [:]
            for row in corpus.records {
                let screenshot = try row.screen.map { try image(fixtureRoot.appendingPathComponent($0)) }
                let start = now()
                docs[row.record.id] = try await e.embedDocument(text: row.record.annotation.text, title: row.record.window?.title, image: screenshot)
                dm[row.record.id] = elapsed(start)
            }
            for q in set.queries {
                let start = now(); qs[q.id] = try await e.embedQuery(q.text); qm[q.id] = elapsed(start)
            }
            cache = VectorCache(corpusHash: digest(corpusData), queryHash: digest(queryData), indexSignature: config.indexSignature,
                                dimension: config.dimension, computeUnits: units.rawValue, documents: docs, queries: qs,
                                documentMilliseconds: dm, queryMilliseconds: qm, preparationMilliseconds: prepareMs)
            try writeJSON(cache, to: cacheURL)
        }
        guard Set(cache.documents.keys) == Set(corpus.records.map { $0.record.id }), Set(cache.queries.keys) == Set(set.queries.map(\.id)) else { throw EvaluationError.invalid("cache ID coverage mismatch") }
        for v in Array(cache.documents.values) + Array(cache.queries.values) {
            let norm = v.reduce(Float(0)) { $0 + $1 * $1 }
            guard v.count == config.dimension, v.allSatisfy(\.isFinite), abs(norm - 1) < 0.01 else { throw EvaluationError.invalid("invalid vector shape/norm") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc-search-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CCPaths(dataRoot: root, modelsRoot: modelsRoot)
        let store = try SQLiteRecordStore(paths: paths)
        let start = now()
        let generation = try await store.beginGeneration(config.pipeline)
        for row in corpus.records {
            try await store.insert(row.record)
            guard let input = try await store.embeddingInput(id: row.record.id),
                  try await store.commitEmbedding(SignedEmbedding(vector: cache.documents[row.record.id]!, compatibilityKey: config.indexSignature), input: input) else {
                throw EvaluationError.invalid("fixture indexing became obsolete")
            }
        }
        guard try await store.activateGeneration(generation.id) else { throw EvaluationError.invalid("fixture generation incomplete") }
        let storeMs = elapsed(start)
        let size = try FileManager.default.attributesOfItem(atPath: paths.databaseURL.path)[.size] as? NSNumber
        if o.liveQueries, coreML == nil {
            let e = CoreMLEmbedder(configuration: config); _ = try await e.prepare(includeVision: false); coreML = e
        }
        var frozenQueries: [String: [Float]] = [:]
        for q in set.queries { frozenQueries[q.text] = cache.queries[q.id] }
        let provider: any Embedder = o.liveQueries ? coreML! : FrozenEmbedder(compatibilityKey: config.indexSignature, dimension: config.dimension, vectors: frozenQueries)
        let vectorHandler = MCPToolHandlers(store: store, embedderProvider: { provider })
        let keywordHandler = MCPToolHandlers(store: store)
        var reports: [String: ModeReport] = [:]
        for (mode, handler, expected) in [("baseline_mcp_vector", vectorHandler, "vector"), ("baseline_mcp_keyword", keywordHandler, "keyword")] {
            var results: [QueryResult] = []
            for q in set.queries {
                var times: [Double] = [], ranked: [RankedItem] = []
                for _ in 0..<repeats {
                    let start = now()
                    let reply = try await handler.call(name: "search_captures", arguments: ["query": .string(q.text), "limit": .int(depth), "include_archived": .bool(q.includeArchived)], clientName: "search-evaluation")
                    guard reply.isError != true else { throw EvaluationError.invalid("MCP returned error for \(q.id)") }
                    guard case let .text(text, _, _) = reply.content.first else { throw EvaluationError.invalid("MCP returned no JSON") }
                    let body = try JSONDecoder().decode(MCPResultBody.self, from: Data(text.utf8))
                    guard body.mode == expected else { throw EvaluationError.invalid("unexpected fallback for \(q.id): \(body.mode)") }
                    ranked = body.items.map { RankedItem(recordID: $0.id, score: $0.score) }
                    times.append(elapsed(start))
                }
                results.append(QueryResult(query: q, items: ranked, milliseconds: times))
            }
            reports[mode] = ModeReport(summaries: summaries(results), results: results)
        }
        var pocMetadata: [String: String] = [:]
        if o.poc {
            let measured = try await evaluatePoC(corpus: corpus, queries: set.queries, cache: cache, store: store, root: root, repeats: repeats, depth: depth)
            reports.merge(measured.0) { _, new in new }; pocMetadata = measured.1
        }
        var report = Report(corpusID: corpus.corpusID, metadata: [
            "corpus_sha256": digest(corpusData), "queries_sha256": digest(queryData), "model_signature": config.indexSignature,
            "compute_units": units.rawValue, "index_vector_compute_units": cache.computeUnits,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "retrieval_depth": String(depth),
            "physical_memory_bytes": String(ProcessInfo.processInfo.physicalMemory), "processor_count": String(ProcessInfo.processInfo.activeProcessorCount),
            "query_source": o.liveQueries ? "live CoreMLEmbedder; latency includes query inference + MCP + store" : "frozen CoreML vectors; latency is retrieval only",
            "document_inputs": "annotation + window title; image only when fixture screen is present; no app/url metadata added",
            "preparation_milliseconds": String(cache.preparationMilliseconds), "store_index_milliseconds": String(storeMs),
            "database_bytes": size.map { String($0.int64Value) } ?? "unknown", "mrr_depth": String(depth),
            "cold_latency": "first-pass percentile is separate; model load/first prepare recorded separately",
            "baseline_contract": "actual MCPToolHandlers.search_captures with actual SQLiteRecordStore"], modes: reports)
        report.metadata.merge(pocMetadata) { _, new in new }
        try writeJSON(report, to: outputURL)
        if let coreML { await coreML.unload() }
        print("wrote \(outputURL.path): \(corpus.records.count) records, \(set.queries.count) queries")
        for (name, result) in reports.sorted(by: { $0.key < $1.key }) {
            let s = result.summaries["split:holdout"]!
            print("\(name) holdout Recall@3=\(s.recall["3"] ?? 0) MRR=\(s.mrr ?? 0) no-answer empty=\(s.noAnswerEmptyRate ?? 0)")
        }
    }
}
