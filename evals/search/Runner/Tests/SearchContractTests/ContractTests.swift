import CCCore
import CCStore
import Foundation
import XCTest
import SearchEvaluation
@testable import SearchContracts
final class ContractTests: XCTestCase {
    var fixtures: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func load() throws -> (FrozenVectors,Corpus,QuerySet,Data,Data) {
        let c=try Data(contentsOf:fixtures.appendingPathComponent("records.json")),q=try Data(contentsOf:fixtures.appendingPathComponent("queries.json"))
        return (try JSONDecoder().decode(FrozenVectors.self,from:Data(contentsOf:fixtures.appendingPathComponent("frozen-vectors.json"))),try CCJSON.decoder().decode(Corpus.self,from:c),try JSONDecoder().decode(QuerySet.self,from:q),c,q)
    }
    func testGoldenCorpusUsesRealStoreAndEveryFilter() async throws {
        let report=try await Contracts.evaluate(fixtures:fixtures)
        XCTAssertEqual(report.modes.count,5)
        let s=try XCTUnwrap(report.modes["baseline_native_vector"]?.summaries["split:holdout"])
        XCTAssertEqual(s.answerableCount,80);XCTAssertEqual(s.noAnswerCount,8)
        XCTAssertGreaterThan(s.recall["3"]!,0.93)
        for mode in report.modes.values { XCTAssertEqual(mode.results.count,176) }
    }
    func testRejectsStaleHashesMissingVectorsAndInvalidPipeline() throws {
        let (original,c,q,cd,qd)=try load()
        XCTAssertNoThrow(try original.validate(corpus:c,set:q,corpusData:cd,queryData:qd))
        var f=original;f.corpusHash="wrong"
        XCTAssertThrowsError(try f.validate(corpus:c,set:q,corpusData:cd,queryData:qd))
        f=original;f.queries.removeValue(forKey:q.queries[0].id)
        XCTAssertThrowsError(try f.validate(corpus:c,set:q,corpusData:cd,queryData:qd))
        f=original;f.pipeline.runtime="different"
        XCTAssertThrowsError(try f.validate(corpus:c,set:q,corpusData:cd,queryData:qd))
        f=original;f.documents[c.records[0].record.id]=[Float](repeating:.nan,count:256)
        XCTAssertThrowsError(try f.validate(corpus:c,set:q,corpusData:cd,queryData:qd))
    }
    func testCASDeletionAndWrongQueryGenerationOnActualSQLite() async throws {
        let (f,c,_,_,_)=try load(); let record=c.records[0].record
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try SQLiteRecordStore(paths:CCPaths(dataRoot:root,modelsRoot:root))
        let g=try await store.beginGeneration(f.pipeline);try await store.insert(record)
        let oldValue=try await store.embeddingInput(id:record.id);let old=try XCTUnwrap(oldValue)
        try await store.modify(id:record.id) { $0.annotation.text="edited synthetic annotation" }
        let vector=f.documents[record.id]!
        let signed=SignedEmbedding(vector:vector,compatibilityKey:f.indexSignature)
        let obsolete=try await store.commitEmbedding(signed,input:old);XCTAssertFalse(obsolete)
        let currentValue=try await store.embeddingInput(id:record.id);let current=try XCTUnwrap(currentValue)
        let accepted=try await store.commitEmbedding(signed,input:current);XCTAssertTrue(accepted)
        let active=try await store.activateGeneration(g.id);XCTAssertTrue(active)
        do { _=try await store.search(vector:vector,limit:3,statuses:[],compatibilityKey:"wrong");XCTFail("wrong key accepted") } catch {}
        try await store.delete(id:record.id)
        let hits=try await store.search(vector:vector,limit:3,statuses:[],compatibilityKey:f.indexSignature);XCTAssertTrue(hits.isEmpty)
    }
}
