import CCCore
import CCStore
import CryptoKit
import Foundation
import SearchEvaluation
import SearchPoC

public struct FrozenVectors: Codable {
    public var schemaVersion: Int
    public var corpusHash: String
    public var queryHash: String
    public var indexSignature: String
    public var dimension: Int
    public var pipeline: EmbeddingPipeline
    public var documents: [String: [Float]]
    public var queries: [String: [Float]]
    public var provenance: String
    public func validate(corpus: Corpus, set: QuerySet, corpusData: Data, queryData: Data) throws {
        func digest(_ d: Data) -> String { SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined() }
        guard schemaVersion==1, dimension==256, pipeline.dimension==dimension, indexSignature==pipeline.compatibilityKey,
              corpusHash==digest(corpusData), queryHash==digest(queryData),
              Set(documents.keys)==Set(corpus.records.map { $0.record.id }), Set(queries.keys)==Set(set.queries.map(\.id)) else { throw EvaluationError.invalid("stale/incomplete frozen vectors") }
        for vector in Array(documents.values)+Array(queries.values) {
            guard vector.count==dimension, vector.allSatisfy(\.isFinite), abs(vector.reduce(Float(0)) { $0+$1*$1 }-1)<0.01 else { throw EvaluationError.invalid("invalid frozen vector") }
        }
    }
}
public struct ContractMode: Codable { public var summaries: [String: Summary]; public var results: [QueryResult] }
public struct ContractReport: Codable {
    public var schemaVersion=1
    public var corpusID: String
    public var metadata: [String:String]
    public var modes: [String:ContractMode]
}
public enum Contracts {
    public static func evaluate(fixtures: URL, frozenFile: URL?=nil) async throws -> ContractReport {
        let corpusData=try Data(contentsOf:fixtures.appendingPathComponent("records.json")), queryData=try Data(contentsOf:fixtures.appendingPathComponent("queries.json"))
        let corpus=try CCJSON.decoder().decode(Corpus.self,from:corpusData), set=try JSONDecoder().decode(QuerySet.self,from:queryData)
        try set.validate(corpus:corpus)
        let frozen=try JSONDecoder().decode(FrozenVectors.self,from:Data(contentsOf:frozenFile ?? fixtures.appendingPathComponent("frozen-vectors.json")))
        try frozen.validate(corpus:corpus,set:set,corpusData:corpusData,queryData:queryData)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cc-search-contract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try SQLiteRecordStore(paths:CCPaths(dataRoot:root,modelsRoot:root.appendingPathComponent("no-models")))
        let generation=try await store.beginGeneration(frozen.pipeline)
        let indexStart=DispatchTime.now().uptimeNanoseconds
        for fixture in corpus.records {
            let r=fixture.record; try await store.insert(r)
            guard let input=try await store.embeddingInput(id:r.id), try await store.commitEmbedding(SignedEmbedding(vector:frozen.documents[r.id]!,compatibilityKey:frozen.indexSignature),input:input) else { throw EvaluationError.invalid("fixture CAS rejected") }
        }
        guard try await store.activateGeneration(generation.id) else { throw EvaluationError.invalid("fixture index incomplete") }
        let keyword=try KeywordIndex(records:corpus.records.map(\.record),file:root.appendingPathComponent("keyword.sqlite"))
        let indexMs=Double(DispatchTime.now().uptimeNanoseconds-indexStart)/1e6
        let records=Dictionary(uniqueKeysWithValues:corpus.records.map { ($0.record.id,$0.record) })
        var rows: [String:[QueryResult]]=[:]
        for q in set.queries {
            let statuses: Set<RecordStatus>=q.includeArchived ? [] : [.inbox,.done]
            let vector=try await store.search(vector:frozen.queries[q.id]!,limit:50,statuses:statuses,compatibilityKey:frozen.indexSignature).map { RankedItem(recordID:$0.record.id,score:Double($0.score)) }
            let word=try keyword.search(q.text,includeArchived:q.includeArchived,trigram:false,limit:50).map { RankedItem(recordID:$0.recordID,score:$0.score) }
            let tri=try keyword.search(q.text,includeArchived:q.includeArchived,trigram:true,limit:50).map { RankedItem(recordID:$0.recordID,score:$0.score) }
            let ranked=["baseline_native_vector":Array(vector.prefix(30)),"poc_unicode61":Array(word.prefix(30)),"poc_trigram_short_exact":Array(tri.prefix(30)),
                        "poc_rrf":Fusion.rrf([vector,tri]),"poc_gated_rrf":Fusion.rrf([Fusion.gate(vector,threshold:0.65,exactLookup:SearchText.exactLookup(q.text)),tri])]
            for (mode,items) in ranked {
                guard items.allSatisfy({ records[$0.recordID] != nil && (q.includeArchived || records[$0.recordID]!.status != .archived) }) else { throw EvaluationError.invalid("unknown ID or archived filter regression") }
                rows[mode,default:[]].append(QueryResult(query:q,items:items,milliseconds:[]))
            }
        }
        var modes:[String:ContractMode]=[:]
        for (mode,results) in rows {
            var groups:[String:[QueryResult]]=["ALL":results]
            for r in results { groups["split:\(r.split)",default:[]].append(r);for tag in r.tags { groups["tag:\(tag)",default:[]].append(r) } }
            modes[mode]=ContractMode(summaries:groups.mapValues(Summary.aggregate),results:results)
        }
        return ContractReport(corpusID:corpus.corpusID,metadata:["corpus_sha256":frozen.corpusHash,"queries_sha256":frozen.queryHash,"model_signature":frozen.indexSignature,
          "scope":"actual SQLiteRecordStore + vDSP + native FTS5/Fusion; frozen CoreML synthetic vectors; no model inference / MCP serialization",
          "sqlite_version":keyword.sqliteVersion,"threshold":"0.65 fixed from #7 dev only; never re-tuned in CI","index_milliseconds":String(indexMs),"os":ProcessInfo.processInfo.operatingSystemVersionString],modes:modes)
    }
}
