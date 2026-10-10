import CoreGraphics
import XCTest
@testable import CCEmbedding

/// モデル 1 つをプロセス内で使い回す（ANE 向けの初回コンパイルが数分かかるため）。
/// 計算ユニットは `CC_EMBEDDING_COMPUTE_UNITS`（cpuAndNeuralEngine / cpuAndGPU / all / cpuOnly）で変えられる（既定 ANE）。
actor SharedEmbeddingModel {
    static let shared = SharedEmbeddingModel()

    struct Results {
        let docs: [[Float]], textQueries: [[Float]], imageQueries: [[Float]], images: [[Float]], fused: [[Float]]
        let peakAfterMB: Double
    }

    private(set) var embedder: CoreMLEmbedder?
    private(set) var firstPrepare: CoreMLEmbedder.PrepareReport?
    private var results: Results?

    func get() async throws -> CoreMLEmbedder {
        if let embedder { return embedder }
        guard let dir = EmbeddingFixtures.modelDirectory() else {
            throw XCTSkip("EmbeddingGemma 2 model not found (CC_MODELS_DIR/embeddinggemma-2 or spikes/fluid/models/swift-dir)")
        }
        let env = ProcessInfo.processInfo.environment["CC_EMBEDDING_COMPUTE_UNITS"].flatMap(EmbeddingComputeUnits.init(rawValue:))
        let units = env ?? .cpuAndNeuralEngine
        let e = CoreMLEmbedder(configuration: .init(modelDirectory: dir, textComputeUnits: units, visionComputeUnits: units))
        metric("model dir: \(dir.path), compute units: \(units.rawValue), load average: \(loadAverage())")
        let start = Date()
        firstPrepare = try await e.prepare()
        metric(String(format: "first prepare (load + first inference): %.1f s at %@ %@", Date().timeIntervalSince(start),
                      ISO8601DateFormatter().string(from: start), String(describing: firstPrepare!)))
        embedder = e
        return e
    }

    /// 参照と同じ入力の 768 次元を全部計算する（1 回だけ）。
    func all() async throws -> Results {
        if let results { return results }
        let e = try await get()
        let meta = try EmbeddingFixtures.referenceMeta()
        let ds = try EmbeddingFixtures.dataset()
        let screens = Dictionary(uniqueKeysWithValues: ds.screens.map { ($0.id, $0) })
        var docs: [[Float]] = [], fused: [[Float]] = [], images: [[Float]] = []
        for (i, c) in ds.captures.enumerated() {
            let s = screens[c.screen]!
            let text = c.text + "\n" + ds.metaText(s)
            // 公開 API と同じ組み立てで参照の文字列になること
            XCTAssertEqual(EmbeddingPrompt.document(text: text, title: s.window_title), meta.doc_texts[i])
            XCTAssertEqual(EmbeddingPrompt.fused(text: c.text, title: s.window_title), meta.fused_texts[i])
            docs.append(try await e.documentEmbedding768(text: text, title: s.window_title, image: nil))
            fused.append(try await e.documentEmbedding768(text: c.text, title: s.window_title, image: try EmbeddingFixtures.screen(c.screen)))
        }
        for sid in meta.scr_ids { images.append(try await e.imageEmbedding768(try EmbeddingFixtures.screen(sid))) }
        var tq: [[Float]] = [], iq: [[Float]] = []
        for q in ds.text_queries {
            XCTAssertTrue(meta.text_queries.contains(EmbeddingPrompt.query(q.q)))
            tq.append(try await e.queryEmbedding768(q.q))
        }
        for q in ds.image_queries { iq.append(try await e.queryEmbedding768(q.q)) }
        let r = Results(docs: docs, textQueries: tq, imageQueries: iq, images: images, fused: fused,
                        peakAfterMB: memoryFootprintMB().peak)
        results = r
        return r
    }
}

/// モデル結合テスト（モデルが無ければ skip）。メソッド名の番号順に走る（XCTest はアルファベット順）。
final class EmbeddingModelIntegrationTests: XCTestCase {
    private var model: SharedEmbeddingModel { SharedEmbeddingModel.shared }

    func test01_LoadAndReload() async throws {
        let e = try await model.get()
        let loaded = await e.isLoaded
        XCTAssertTrue(loaded)
        let visionLoaded = await e.isVisionLoaded
        XCTAssertTrue(visionLoaded)
        await e.unload()
        let afterUnload = await e.isLoaded
        XCTAssertFalse(afterUnload)
        let start = Date()
        let second = try await e.prepare()
        metric(String(format: "second prepare after unload (same process): %.1f s %@", Date().timeIntervalSince(start),
                      String(describing: second)))
        // 2 回目は ANE のキャッシュが効く（初回の数分に対して数十秒以内）
        XCTAssertLessThan(second.textLoadSeconds + second.visionLoadSeconds, 120)
    }

    func test02_CosineAgainstPyTorchReference() async throws {
        let r = try await model.all()
        let npz = try NPZ(EmbeddingFixtures.require("spikes/runtime/data/embed_reference.npz"))
        let pairs: [(String, [[Float]])] = [("text_docs", r.docs), ("text_queries", r.textQueries),
                                             ("image_queries", r.imageQueries), ("images", r.images), ("fused", r.fused)]
        for (name, mine) in pairs {
            let ref = try npz.array(name).rows
            XCTAssertEqual(ref.count, mine.count, name)
            let cos = zip(mine, ref).map { Double(EmbeddingVector.cosine($0, $1)) }
            let cos256 = zip(mine, ref).map {
                Double(EmbeddingVector.cosine(EmbeddingVector.truncateAndNormalize($0, to: 256),
                                              EmbeddingVector.truncateAndNormalize($1, to: 256)))
            }
            metric(String(format: "cosine vs PyTorch %@ (n=%d): 768 min %.5f mean %.5f / 256 min %.5f mean %.5f", name,
                          cos.count, cos.min()!, cos.reduce(0, +) / Double(cos.count), cos256.min()!,
                          cos256.reduce(0, +) / Double(cos256.count)))
            XCTAssertGreaterThanOrEqual(cos.min()!, 0.995, name)
        }
    }

    func test03_Retrieval() async throws {
        let r = try await model.all()
        let ds = try EmbeddingFixtures.dataset()
        let meta = try EmbeddingFixtures.referenceMeta()
        let tRel = ds.text_queries.map(\.relevant), iRel = ds.image_queries.map(\.relevant)
        for dim in [768, 256] {
            func t(_ m: [[Float]]) -> [[Float]] { m.map { EmbeddingVector.truncateAndNormalize($0, to: dim) } }
            let text = recallMRR(queries: t(r.textQueries), docs: t(r.docs), docIDs: meta.cap_ids, relevant: tRel)
            let fused = recallMRR(queries: t(r.textQueries), docs: t(r.fused), docIDs: meta.cap_ids, relevant: tRel)
            let image = recallMRR(queries: t(r.imageQueries), docs: t(r.images), docIDs: meta.scr_ids, relevant: iRel)
            metric(String(format: "retrieval %d: text R@3 %.3f MRR %.3f / fused R@3 %.3f MRR %.3f / image-only R@3 %.3f MRR %.3f",
                          dim, text.recall, text.mrr, fused.recall, fused.mrr, image.recall, image.mrr))
            if dim == 256 { XCTAssertGreaterThanOrEqual(fused.recall, 0.9) }
        }
    }

    /// 公開 API（256 次元）が 768 次元の先頭 256 の再正規化と一致し、単位ベクトルであること。
    func test04_PublicAPIIs256Normalized() async throws {
        let e = try await model.get()
        let r = try await model.all()
        let ds = try EmbeddingFixtures.dataset()
        let s = ds.screens.first { $0.id == ds.captures[0].screen }!
        let q = try await e.embedQuery(ds.text_queries[0].q)
        let d = try await e.embedDocument(text: ds.captures[0].text + "\n" + ds.metaText(s), title: s.window_title, image: nil)
        let f = try await e.embedDocument(text: ds.captures[0].text, title: s.window_title, image: try EmbeddingFixtures.screen(s.id))
        for (v, full) in [(q, r.textQueries[0]), (d, r.docs[0]), (f, r.fused[0])] {
            XCTAssertEqual(v.count, 256)
            XCTAssertEqual(v.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-4)
            XCTAssertGreaterThan(EmbeddingVector.cosine(v, EmbeddingVector.truncateAndNormalize(full, to: 256)), 0.9999)
        }
        // 同じ埋め込みでもう一度（決定的であること）
        let q2 = try await e.embedQuery(ds.text_queries[0].q)
        XCTAssertGreaterThan(EmbeddingVector.cosine(q, q2), 0.9999)
    }

    /// 1 件のレイテンシ（3 周、各周の中央値の中央値）。
    func test05_Latency() async throws {
        let e = try await model.get()
        let ds = try EmbeddingFixtures.dataset()
        let screens = Dictionary(uniqueKeysWithValues: ds.screens.map { ($0.id, $0) })
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let load = loadAverage()
        var docReps: [Double] = [], queryReps: [Double] = [], fusedReps: [Double] = [], prepReps: [Double] = []
        let fusedItems = Array(ds.captures.prefix(10))
        for _ in 0..<3 {
            var l: [Double] = []
            for c in ds.captures {
                let s = screens[c.screen]!
                let t = Date()
                _ = try await e.embedDocument(text: c.text + "\n" + ds.metaText(s), title: s.window_title, image: nil)
                l.append(Date().timeIntervalSince(t))
            }
            docReps.append(median(l))
            l = []
            for q in ds.text_queries {
                let t = Date()
                _ = try await e.embedQuery(q.q)
                l.append(Date().timeIntervalSince(t))
            }
            queryReps.append(median(l))
            l = []
            var lp: [Double] = []
            for c in fusedItems {
                let img = try EmbeddingFixtures.screen(c.screen)
                var t = Date()
                _ = try autoreleasepool { try ImagePreprocessor.prepare(img, budget: .tokens280, positionTable: Data(count: 2 * 1024 * 768 * 2)) }
                lp.append(Date().timeIntervalSince(t))
                t = Date()
                _ = try await e.embedDocument(text: c.text, title: screens[c.screen]!.window_title, image: img)
                l.append(Date().timeIntervalSince(t))
            }
            fusedReps.append(median(l))
            prepReps.append(median(lp))
        }
        metric(String(format: "latency started %@ (load avg %@ → %@): doc %.1f ms %@ / query %.1f ms %@ / fused %.3f s %@ / preprocess only %.3f s",
                      startedAt, load, loadAverage(), median(docReps) * 1000, docReps.map { String(format: "%.1f", $0 * 1000) }.description,
                      median(queryReps) * 1000, queryReps.map { String(format: "%.1f", $0 * 1000) }.description,
                      median(fusedReps), fusedReps.map { String(format: "%.3f", $0) }.description, median(prepReps)))
    }

    /// 1 件ごとに autoreleasepool を抜けているので、画像 44 件 + 文 70 件を処理してもピークが 1GB 未満。
    func test06_PeakMemory() async throws {
        let r = try await model.all()
        let now = memoryFootprintMB()
        metric(String(format: "footprint now %.0f MB, peak after all embeddings %.0f MB, lifetime peak %.0f MB",
                      now.current, r.peakAfterMB, now.peak))
        XCTAssertLessThan(now.peak, 1000)
    }
}
