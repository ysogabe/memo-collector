import CCCore
import Foundation
import GRDB
import XCTest
@testable import CCStore

final class IndexGenerationTests: XCTestCase {
    func pipeline(_ revision: String = "a") -> EmbeddingPipeline {
        EmbeddingPipeline(modelID: "synthetic", revision: revision, runtime: "test", quantization: "f32", dimension: 256,
                          imageTokens: 280, preprocessingVersion: "1")
    }
    func fill(_ store: SQLiteRecordStore, _ id: String, _ generation: IndexGeneration, axis: Int = 0) async throws {
        let input = try unwrapGeneration(try await store.embeddingInput(id: id))
        assertGenerationEqual(input.generationID, generation.id)
        let saved = try await store.commitEmbedding(SignedEmbedding(vector: unitVector([axis: 1]), compatibilityKey: generation.pipeline.compatibilityKey), input: input)
        assertGenerationTrue(saved)
    }
    func testShadowSwitchDoesNotMixSpacesAndRetainsOldVectors() async throws {
        let root = try TempDataRoot(), store = try root.makeStore()
        let record = makeRecord(); try await store.insert(record)
        let a = try await store.beginGeneration(pipeline())
        try await fill(store,record.id,a)
        assertGenerationTrue(try await store.activateGeneration(a.id))
        let other = try root.makeStore()
        assertGenerationEqual(try await other.search(vector: unitVector([0:1]),limit:1,statuses:[],compatibilityKey:a.pipeline.compatibilityKey).first?.record.id,record.id)
        let b = try await store.beginGeneration(pipeline("b"))
        assertGenerationEqual(try await store.activeGeneration()?.id,a.id)
        assertGenerationFalse(try await store.activateGeneration(b.id))
        try await fill(store,record.id,b,axis:1)
        assertGenerationTrue(try await store.activateGeneration(b.id))
        do { _ = try await other.search(vector:unitVector([0:1]),limit:1,statuses:[],compatibilityKey:a.pipeline.compatibilityKey); XCTFail("mixed spaces") } catch CCStoreError.invalidGeneration { }
        assertGenerationEqual(try await other.search(vector:unitVector([1:1]),limit:1,statuses:[],compatibilityKey:b.pipeline.compatibilityKey).first?.score,1)
        assertGenerationTrue(try await store.rollbackGeneration(a.id))
        let count = try await store.pool.read { try Int.fetchOne($0,sql:"SELECT count(*) FROM generation_embeddings")! }
        assertGenerationEqual(count,2)
    }
    func testEditAndDeleteDuringRebuildRejectObsoleteWritesAndPersistPending() async throws {
        let root = try TempDataRoot(), store = try root.makeStore()
        let r=makeRecord(); try await store.insert(r)
        let g=try await store.beginGeneration(pipeline())
        let old=try unwrapGeneration(try await store.embeddingInput(id:r.id))
        _ = try await store.modify(id:r.id) { $0.annotation.text="編集後" }
        assertGenerationFalse(try await store.commitEmbedding(SignedEmbedding(vector:unitVector([0:1]),compatibilityKey:g.pipeline.compatibilityKey),input:old))
        let reopened=try root.makeStore()
        assertGenerationEqual(try await reopened.beginGeneration(pipeline()).id,g.id)
        assertGenerationEqual(try await reopened.missingGenerationIDs(g.id,limit:10),[r.id])
        try await fill(reopened,r.id,g)
        assertGenerationTrue(try await reopened.activateGeneration(g.id))
        let latest=try unwrapGeneration(try await reopened.embeddingInput(id:r.id))
        try await reopened.delete(id:r.id)
        assertGenerationFalse(try await store.commitEmbedding(SignedEmbedding(vector:unitVector([0:1]),compatibilityKey:g.pipeline.compatibilityKey),input:latest))
        let count=try await store.pool.read { try Int.fetchOne($0,sql:"SELECT count(*) FROM generation_jobs")! }
        assertGenerationEqual(count,0)
    }
    func testNewCapturePreventsSwitchAndStaleVectorsLeaveSearchImmediately() async throws {
        let root=try TempDataRoot(), store=try root.makeStore(), r=makeRecord()
        try await store.insert(r)
        let g=try await store.beginGeneration(pipeline()); try await fill(store,r.id,g)
        let new=makeRecord(at:1); try await store.insert(new)
        assertGenerationFalse(try await store.activateGeneration(g.id))
        try await fill(store,new.id,g); assertGenerationTrue(try await store.activateGeneration(g.id))
        _ = try await store.modify(id:r.id) { $0.window=WindowInfo(title:"別の題名",frame:nil) }
        let hits=try await store.search(vector:unitVector([0:1]),limit:10,statuses:[],compatibilityKey:g.pipeline.compatibilityKey)
        assertGenerationEqual(hits.map(\.record.id),[new.id])
        let missing=try await store.idsWithoutEmbedding(); assertGenerationEqual(missing,[r.id])
    }
    func testV1MigrationBacksUpAndKeepsRecordAndLegacyBlob() async throws {
        let root=try TempDataRoot(), record=makeRecord()
        let old=try DatabaseQueue(path:root.paths.databaseURL.path)
        try StoreSchema.migrator.migrate(old,upTo:"v1")
        let blob=VectorCodec.encode(unitVector([0:1]))
        try await old.write { db in
            try RecordRow.insert(record,db:db)
            try db.execute(sql:"INSERT INTO embeddings(record_id,dim,vector) VALUES(?,?,?)",arguments:[record.id,256,blob])
        }
        let migrated=try root.makeStore()
        assertGenerationEqual(try await migrated.get(id:record.id),record)
        let preserved=try await migrated.pool.read { try Data.fetchOne($0,sql:"SELECT vector FROM embeddings WHERE record_id=?",arguments:[record.id]) }
        assertGenerationEqual(preserved,blob)
        let backup=root.paths.databaseURL.appendingPathExtension("pre-index-v2-backup")
        assertGenerationTrue(FileManager.default.fileExists(atPath:backup.path))
        let snapshot=try DatabaseQueue(path:backup.path)
        let identifiers=try await snapshot.read { try String.fetchAll($0,sql:"SELECT identifier FROM grdb_migrations") }
        assertGenerationEqual(identifiers,["v1"])
    }
    func testReferencedRawScreenshotCannotBeOverwritten() async throws {
        let root=try TempDataRoot(), store=try root.makeStore()
        var r=makeRecord()
        let original=Data([1,2,3])
        r.screenshotPath=try await store.writeAttachment(original,id:r.id,kind:.screenshot,ext:"png",capturedAt:r.capturedAt)
        try await store.insert(r)
        do { _ = try await store.writeAttachment(Data([4,5,6]),id:r.id,kind:.screenshot,ext:"png",capturedAt:r.capturedAt); XCTFail("overwrite recorded input") }
        catch CCStoreError.immutableAttachment { }
        let url=try await store.attachmentURL(for:r.screenshotPath!)
        XCTAssertEqual(try Data(contentsOf:url),original)
    }

    func testWrongSpaceAndUnversionedCommitCannotPopulateShadow() async throws {
        let root=try TempDataRoot(), store=try root.makeStore(), r=makeRecord()
        try await store.insert(r)
        let legacy=try unwrapGeneration(try await store.embeddingInput(id:r.id))
        let g=try await store.beginGeneration(pipeline())
        let current=try unwrapGeneration(try await store.embeddingInput(id:r.id))
        assertGenerationFalse(try await store.commitEmbedding(SignedEmbedding(vector:unitVector([0:1]),compatibilityKey:pipeline("wrong").compatibilityKey),input:current))
        assertGenerationFalse(try await store.commitEmbedding(SignedEmbedding(vector:unitVector([0:1]),compatibilityKey:g.pipeline.compatibilityKey),input:legacy))
        do { try await store.setEmbedding(id:r.id,vector:unitVector([0:1])); XCTFail("unsigned commit") }
        catch CCStoreError.invalidGeneration { }
        assertGenerationEqual(try await store.missingGenerationIDs(g.id,limit:10),[r.id])
    }
    func testRollbackRefusesOldGenerationAfterAnEdit() async throws {
        let root=try TempDataRoot(), store=try root.makeStore(), r=makeRecord()
        try await store.insert(r)
        let a=try await store.beginGeneration(pipeline()); try await fill(store,r.id,a)
        assertGenerationTrue(try await store.activateGeneration(a.id))
        let b=try await store.beginGeneration(pipeline("b")); try await fill(store,r.id,b)
        assertGenerationTrue(try await store.activateGeneration(b.id))
        _ = try await store.modify(id:r.id) { $0.annotation.text="新しい入力" }
        try await fill(store,r.id,b)
        assertGenerationFalse(try await store.rollbackGeneration(a.id))
        assertGenerationEqual(try await store.activeGeneration()?.id,b.id)
    }

    private func assertGenerationTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, file: file, line: line)
    }
    private func assertGenerationFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value, file: file, line: line)
    }
    private func assertGenerationEqual<T: Equatable>(_ value: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, expected, file: file, line: line)
    }
    private func unwrapGeneration<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

}
