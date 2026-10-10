import CCCore
import CryptoKit
import Foundation
import XCTest
@testable import CCModels

/// Wave 6: 埋め込みの manifest の無い既存を取り直さずに採用する・d1 のサイズだけの検証。
/// どれも一時ディレクトリのダミーで（モデル・ネットワーク不要。spikes/dev-models には書き込まない）。
final class Wave6PreparerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("w6-prep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ s: String, _ rel: String, in root: URL) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: u)
    }

    private func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    // MARK: - 埋め込み: .unmanifested の採用

    /// manifest の無いダミーの置き場と、その中身に合わせた `sourceFiles`（固定 revision の sha256 の代わり）を作る。
    private func makeUnmanifestedEmbedding() throws -> EmbeddingModelPreparer {
        let dest = tmp.appendingPathComponent("embeddinggemma-2")
        let copied = ["config.json": "{\"c\":1}", "README.md": "readme", "tokenizer.json": "{}",
                      "embeddings.bf16": "eeee", "position_embeddings.f16": "pp"]
        for (k, v) in copied { try write(v, k, in: dest) }
        try write("t", "EmbeddingGemma2Text.mlmodelc/coremldata.bin", in: dest)
        try write("v", "EmbeddingGemma2Vision.mlmodelc/coremldata.bin", in: dest)
        var p = EmbeddingModelPreparer(destination: dest)
        p.sourceFiles = copied.keys.sorted().map { .init(path: $0, size: Int64(copied[$0]!.utf8.count), sha256: sha(copied[$0]!)) }
            + [.init(path: "EmbeddingGemma2Text.mlpackage/Manifest.json", size: 1, sha256: sha("x"))]
        // 取りに行ったら失敗するように（採用の経路がネットワークを使わないことの確認）。
        p.baseURL = URL(string: "http://127.0.0.1:9/")!
        return p
    }

    func testPrepareAdoptsUnmanifestedEmbeddingWithoutNetwork() async throws {
        let p = try makeUnmanifestedEmbedding()
        XCTAssertEqual(try p.verify(level: .size), .unmanifested)
        XCTAssertTrue(try p.canAdoptExisting())

        guard case .prepared(let m) = try await p.prepare() else { return XCTFail("採用して manifest を作る") }
        XCTAssertEqual(m.revision, EmbeddingModelPreparer.revision)
        XCTAssertTrue(m.preparedWith.contains("adopted"))
        XCTAssertEqual(Set(m.sourceFiles.map(\.path)), Set(EmbeddingModelPreparer.copiedFiles), "照合できた元ファイルだけを記録")
        let paths = Set(m.files.map(\.path))
        XCTAssertTrue(paths.isSuperset(of: ["LICENSE", "NOTICE.txt", "EmbeddingGemma2Text.mlmodelc/coremldata.bin", "tokenizer.json"]))
        guard case .ready = try p.verify(level: .sha256) else { return XCTFail("採用後は ready") }

        // 2 回目は何もしない。
        guard case .alreadyPrepared = try await p.prepare() else { return XCTFail() }
    }

    func testDoesNotAdoptEmbeddingWithOtherContentsOrMissingFiles() async throws {
        let p = try makeUnmanifestedEmbedding()
        try Data("EEEE".utf8).write(to: p.destination.appendingPathComponent("embeddings.bf16"))  // 大きさ同じ・中身違い
        XCTAssertFalse(try p.canAdoptExisting())
        XCTAssertThrowsError(try p.adoptExisting()) { error in
            guard case EmbeddingPrepareError.checksumMismatch(let path, _, _)? = error as? EmbeddingPrepareError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(path, "embeddings.bf16")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.manifestURL.path), "採用できなければ何も書かない")
        // 採用できないときは取りに行く（ここでは取得先が無いので失敗する）。
        do {
            _ = try await p.prepare()
            XCTFail("取得に進んで失敗するはず")
        } catch {}

        try FileManager.default.removeItem(at: p.destination.appendingPathComponent("tokenizer.json"))
        XCTAssertFalse(try p.canAdoptExisting())
    }

    // MARK: - d1: verify(level:)

    private func makeD1(_ files: [String: String], manifest: Bool) throws -> D1ModelPreparer {
        let dest = tmp.appendingPathComponent("d1-3b-text-q8")
        for (k, v) in files { try write(v, k, in: dest) }
        if manifest {
            let m = D1ModelManifest(
                repo: D1ModelPreparer.repoId, revision: D1ModelPreparer.revision, conversionVersion: D1ModelPreparer.conversionVersion,
                createdAt: "2026-10-10T00:00:00Z", source: [:], quantization: .init(bits: 8, groupSize: 64, mode: "affine"),
                tensorCount: 1, files: files.mapValues { .init(sha256: sha($0), bytes: $0.utf8.count) })
            try D1ModelManifest.encoder().encode(m).write(to: dest.appendingPathComponent("manifest.json"))
        }
        return D1ModelPreparer(destination: dest)
    }

    func testD1VerifyStatuses() throws {
        let files = ["config.json": "{}", "tokenizer.json": "{\"t\":1}", "model.safetensors": "weights", "LICENSE": "L"]
        let empty = D1ModelPreparer(destination: tmp.appendingPathComponent("none"))
        XCTAssertEqual(try empty.verify(level: .size), .missing(D1ModelPreparer.requiredFiles))

        let unmanifested = try makeD1(files, manifest: false)
        XCTAssertEqual(try unmanifested.verify(level: .size), .unmanifested)

        let p = try makeD1(files, manifest: true)
        guard case .ready(let m) = try p.verify(level: .size) else { return XCTFail() }
        XCTAssertEqual(m.revision, D1ModelPreparer.revision)
        guard case .ready = try p.verify(level: .sha256) else { return XCTFail() }

        // 大きさ同じ・中身違いは sha256 でだけ分かる。
        try Data("WEIGHTS".utf8).write(to: p.destination.appendingPathComponent("model.safetensors"))
        guard case .ready = try p.verify(level: .size) else { return XCTFail("size だけなら通る") }
        XCTAssertEqual(try p.verify(level: .sha256), .mismatched(["model.safetensors"]))
        // 大きさ違いと余計なファイルは size でも分かる。
        try Data("w".utf8).write(to: p.destination.appendingPathComponent("model.safetensors"))
        try write("x", "extra.bin", in: p.destination)
        XCTAssertEqual(try p.verify(level: .size), .mismatched(["extra.bin", "model.safetensors"]))
    }

    /// 開発用の置き場（manifest 無し）が読めるなら unmanifested（読み取り専用。書き込まない）。
    func testDevModelsD1IsUnmanifestedOrReady() throws {
        guard let dir = ProcessInfo.processInfo.environment["CC_MODELS_DIR"], !dir.isEmpty else {
            throw XCTSkip("CC_MODELS_DIR が無い")
        }
        let p = D1ModelPreparer(destination: URL(fileURLWithPath: dir).appendingPathComponent(ModelSlot.d1.directoryName))
        switch try p.verify(level: .size) {
        case .ready, .unmanifested: break
        case .missing: throw XCTSkip("d1 が無い")
        case let .mismatched(bad): XCTFail("\(bad)")
        }
    }
}
