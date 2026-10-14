import CCCore
import CCStore
import CoreGraphics
import Foundation
import XCTest

private final class GenerationEmbedder: PreparableEmbedder, @unchecked Sendable {
    let dimension = 4
    let imageTokens: Int
    let loaded = Box(false)
    init(_ tokens: Int) { imageTokens = tokens }
    var pipeline: EmbeddingPipeline? {
        EmbeddingPipeline(modelID:"synthetic",revision:"1",runtime:"test",quantization:"f32",dimension:4,imageTokens:imageTokens,preprocessingVersion:"1")
    }
    var indexSignature: String { pipeline!.compatibilityKey }
    var isLoaded: Bool { loaded.get() }
    func prepareForUse() async throws { loaded.set(true) }
    func unload() async { loaded.set(false) }
    func loadDescription() async -> String { "test" }
    func embedQuery(_ text: String) async throws -> [Float] { imageTokens == 280 ? [1,0,0,0] : [0,1,0,0] }
    func embedDocument(text: String,title: String?,image: CGImage?) async throws -> [Float] { try await embedQuery(text) }
}
private final class GenerationQueue: TriageQueuing, @unchecked Sendable {
    let store: SQLiteRecordStore
    let fail = Box(false)
    let writes = Box(0)
    init(_ store: SQLiteRecordStore) { self.store = store }
    func enqueue(id: String) async {}
    func annotationEdited(id: String) async {}
    func reindex(id: String) async { _ = await reindexAll(ids:[id]) }
    func resumePending() async throws -> Int { 0 }
    func waitUntilIdle() async {}
    func reindexAll(ids: [String]) async -> [String] {
        if fail.get() { return ids }
        var failed: [String] = []
        for id in ids {
            do {
                guard let input = try await store.embeddingInput(id:id), let target = try await store.targetGeneration() else { failed.append(id); continue }
                let vector: [Float] = target.pipeline.imageTokens == 280 ? [1,0,0,0] : [0,1,0,0]
                let saved = try await store.commitEmbedding(SignedEmbedding(vector:vector,compatibilityKey:target.pipeline.compatibilityKey),input:input)
                if saved { writes.update { $0 += 1 } } else { failed.append(id) }
            } catch { failed.append(id) }
        }
        return failed
    }
}
@MainActor final class SearchGenerationTests: XCTestCase {
    func testFailurePreservesActiveAndResumesSameShadowWithoutMixedSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try SQLiteRecordStore(paths:CCPaths(dataRoot:root,modelsRoot:root.appendingPathComponent("models")),dimension:4)
        let r = ContextRecord(capturedAt:Date().roundedToMilliseconds,app:.unknown,annotation:Annotation(text:"検索メモ",sttEngine:"synthetic"))
        try await store.insert(r)
        let queue = GenerationQueue(store), embedder = SwitchableEmbedder(dimension:4)
        let maintainer = SearchIndexMaintainer(embedder:embedder,queue:queue,store:store,stateURL:SearchIndexState.url(dataRoot:root)) { GenerationEmbedder($0) }
        await maintainer.activate(imageTokens:280).value
        XCTAssertEqual(maintainer.readiness,.ready)
        let initial = try await store.activeGeneration()
        let old = try XCTUnwrap(initial)
        queue.fail.set(true)
        await maintainer.activate(imageTokens:70).value
        XCTAssertEqual(maintainer.readiness,.failed)
        let activeAfterFailure = try await store.activeGeneration()
        XCTAssertEqual(activeAfterFailure?.id,old.id)
        let targetBeforeResume = try await store.targetGeneration()
        let service = EmbeddingSearchService(embedder:embedder,store:store,readiness:{await maintainer.readiness})
        let fallback = try await service.searchWithNotice("検索",limit:10)
        XCTAssertNotNil(fallback.notice)
        queue.fail.set(false)
        await maintainer.activate(imageTokens:70).value
        XCTAssertEqual(maintainer.readiness,.ready)
        let activeAfterResume = try await store.activeGeneration()
        XCTAssertEqual(activeAfterResume?.id,targetBeforeResume?.id)
        let response = try await service.searchWithNotice("検索",limit:10)
        XCTAssertNil(response.notice); XCTAssertEqual(response.hits.first?.score,1)
        let count = queue.writes.get()
        await maintainer.activate(imageTokens:70).value
        XCTAssertEqual(queue.writes.get(),count)
    }
    func testCancelledActivationCannotReplaceLatestTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try SQLiteRecordStore(paths:CCPaths(dataRoot:root,modelsRoot:root.appendingPathComponent("models")),dimension:4)
        let queue = GenerationQueue(store), embedder = SwitchableEmbedder(dimension:4)
        let maintainer = SearchIndexMaintainer(embedder:embedder,queue:queue,store:store,stateURL:SearchIndexState.url(dataRoot:root)) { GenerationEmbedder($0) }
        let obsolete = maintainer.activate(imageTokens:280)
        let latest = maintainer.activate(imageTokens:70)
        await obsolete.value; await latest.value
        let active = try await store.activeGeneration()
        XCTAssertEqual(active?.pipeline.imageTokens,70)
        XCTAssertEqual(maintainer.readiness,.ready)
    }
}
