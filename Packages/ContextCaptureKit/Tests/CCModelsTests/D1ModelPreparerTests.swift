import CCCore
import Foundation
import MLX
import XCTest
@testable import CCModels

final class D1ModelPreparerTests: XCTestCase {
    static let hfSnapshot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".cache/huggingface/hub/models--LiquidAI--d1-3B/snapshots/051bcc464b01b9f92942b364d9586b0ef5912432")

    /// config: text_config ベース + model_type / block_ff_dim / quantization。
    func testMakeConfigFromTextConfig() throws {
        let src = #"{"model_type":"lfm2_vl","text_config":{"model_type":"lfm2","hidden_size":2048,"intermediate_size":10752,"tie_word_embeddings":false},"vision_config":{}}"#
        let data = try D1ModelPreparer.makeConfig(sourceConfig: Data(src.utf8), groupSize: 64, bits: 8)
        let c = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(c["model_type"] as? String, "lfm2")
        XCTAssertEqual(c["block_ff_dim"] as? Int, 10752)
        XCTAssertEqual(c["tie_word_embeddings"] as? Bool, true)
        XCTAssertNil(c["vision_config"])
        let q = try XCTUnwrap(c["quantization"] as? [String: Any])
        XCTAssertEqual(q["bits"] as? Int, 8)
        XCTAssertEqual(q["group_size"] as? Int, 64)
    }

    /// 小さな合成 checkpoint で抽出・改名・conv 転置・量子化の規則を確かめる（モデル不要）。
    func testConvertWeightsRules() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("d1prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model.safetensors")
        let arrays: [String: MLXArray] = [
            "model.language_model.embed_tokens.weight": MLXRandom.normal([8, 128]).asType(.bfloat16),
            "model.language_model.layers.0.conv.conv.weight": MLXRandom.normal([128, 1, 3]).asType(.bfloat16),
            "model.language_model.layers.0.operator_norm.weight": MLXArray.ones([128]).asType(.bfloat16),
            "model.vision_tower.foo.weight": MLXRandom.normal([4, 64]),
            "model.multi_modal_projector.linear.weight": MLXRandom.normal([4, 64]),
        ]
        try save(arrays: arrays, url: url)
        let out = try D1ModelPreparer.convertWeights(url: url, groupSize: 64, bits: 8)
        XCTAssertEqual(Set(out.keys), [
            "model.embed_tokens.weight", "model.embed_tokens.scales", "model.embed_tokens.biases",
            "model.layers.0.conv.conv.weight", "model.layers.0.operator_norm.weight",
        ])
        XCTAssertEqual(out["model.embed_tokens.weight"]!.dtype, .uint32)
        XCTAssertEqual(out["model.embed_tokens.weight"]!.shape, [8, 32])
        XCTAssertEqual(out["model.embed_tokens.scales"]!.shape, [8, 2])
        XCTAssertEqual(out["model.layers.0.conv.conv.weight"]!.shape, [128, 3, 1])
        let back = dequantized(out["model.embed_tokens.weight"]!, scales: out["model.embed_tokens.scales"]!,
                               biases: out["model.embed_tokens.biases"]!, groupSize: 64, bits: 8)
        let err = abs(back.asType(.float32) - arrays["model.language_model.embed_tokens.weight"]!.asType(.float32)).max().item(Float.self)
        XCTAssertLessThan(err, 0.05)
    }

    /// 実モデルの変換（CC_RUN_SLOW=1 かつ HF キャッシュに元モデルがあるときだけ。数分・メモリ数 GB）。
    /// スパイクの Python 変換物（CC_MODELS_DIR/d1-3b-text-q8）と全テンソルが一致することを確かめる。
    func testConvertRealModelMatchesPythonConversion() throws {
        guard ProcessInfo.processInfo.environment["CC_RUN_SLOW"] == "1" else { throw XCTSkip("CC_RUN_SLOW=1 のときだけ") }
        guard FileManager.default.fileExists(atPath: Self.hfSnapshot.appendingPathComponent("model.safetensors").path) else {
            throw XCTSkip("HF キャッシュに d1-3B が無い")
        }
        let reference = CCPaths.resolve().modelDirectory(.d1)
        let outRoot: URL
        if let keep = ProcessInfo.processInfo.environment["CC_D1_PREPARE_OUT"], !keep.isEmpty {
            outRoot = URL(fileURLWithPath: keep, isDirectory: true)
        } else {
            outRoot = FileManager.default.temporaryDirectory.appendingPathComponent("d1prep-real-\(UUID().uuidString)")
        }
        let dest = outRoot.appendingPathComponent(ModelSlot.d1.directoryName, isDirectory: true)
        defer {
            if ProcessInfo.processInfo.environment["CC_D1_PREPARE_OUT"] == nil { try? FileManager.default.removeItem(at: outRoot) }
        }
        Memory.peakMemory = 0  // 変換だけのピークを測る（setter はリセット）
        let t0 = Date()
        let manifest = try D1ModelPreparer(destination: dest).convert(source: Self.hfSnapshot)
        let seconds = Date().timeIntervalSince(t0)
        let convertPeakMB = Memory.peakMemory / 1_000_000
        XCTAssertEqual(manifest.tensorCount, 600)
        XCTAssertEqual(manifest.revision, D1ModelPreparer.revision)
        XCTAssertEqual(try D1ModelPreparer.verify(directory: dest), [])
        for name in ["LICENSE", "NOTICE-MODIFIED.txt", "tokenizer.json", "config.json", "model.safetensors", "manifest.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent(name).path), name)
        }

        guard FileManager.default.fileExists(atPath: reference.appendingPathComponent("model.safetensors").path) else {
            print("D1PREPARE no python reference at \(reference.path); converted in \(seconds) s")
            return
        }
        // ---- config: Python 変換物と同じキー・同じ値（Python 側だけにあるキーは列挙して出す）
        let mine = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dest.appendingPathComponent("config.json"))) as? NSDictionary)
        let theirs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reference.appendingPathComponent("config.json"))) as? NSDictionary)
        var configDiff: [String] = []
        for key in Set(mine.allKeys as! [String]).union(theirs.allKeys as! [String]).sorted() {
            let a = mine[key] as? NSObject, b = theirs[key] as? NSObject
            if a != b { configDiff.append("\(key): swift=\(a.map { "\($0)" } ?? "nil") python=\(b.map { "\($0)" } ?? "nil")") }
        }
        XCTAssertEqual(configDiff, [], "config の差")

        // ---- 重み: キー・形・dtype・値がすべて一致
        let a = try loadArrays(url: dest.appendingPathComponent("model.safetensors"))
        let b = try loadArrays(url: reference.appendingPathComponent("model.safetensors"))
        XCTAssertEqual(Set(a.keys), Set(b.keys))
        var differing: [String] = []
        for key in a.keys.sorted() {
            guard let x = a[key], let y = b[key] else { continue }
            if x.shape != y.shape || x.dtype != y.dtype || !arrayEqual(x, y).item(Bool.self) { differing.append(key) }
        }
        XCTAssertEqual(differing, [], "\(differing.count) tensors differ")
        print("D1PREPARE converted in \(String(format: "%.1f", seconds)) s, conversion peak MLX \(convertPeakMB) MB, "
              + "tensors \(a.count), differing \(differing.count), config diff \(configDiff.count)")
    }

    /// HF から revision 固定で取れること（CC_RUN_NETWORK=1 のときだけ。小さいファイル 1 つだけ取る）。
    func testDownloadPinnedRevisionSmallFile() async throws {
        guard ProcessInfo.processInfo.environment["CC_RUN_NETWORK"] == "1" else { throw XCTSkip("CC_RUN_NETWORK=1 のときだけ") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("d1dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = D1ModelPreparer(destination: root.appendingPathComponent("d1-3b-text-q8"))
        let dir = try await p.download(files: ["config.json"])
        let local = dir.appendingPathComponent("config.json")
        let cached = Self.hfSnapshot.appendingPathComponent("config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        if FileManager.default.fileExists(atPath: cached.path) {
            XCTAssertEqual(try D1ModelPreparer.sha256(of: local), try D1ModelPreparer.sha256(of: cached))
        }
        print("D1DOWNLOAD \(dir.path)")
    }
}
