import CCCore
import Foundation
import XCTest
@testable import CCModels

/// 共通の `ModelManifest` に寄せた後も、既存の manifest.json（各担当が書いた形）を読めること。
/// JSON は各 Preparer が書く形をそのまま写したもの（キー名・日時の形式・`files` の形を固定する）。
final class ModelManifestCompatibilityTests: XCTestCase {
    static let sha = String(repeating: "a", count: 64)

    /// D1ModelPreparer.convert が書く形（`files` が辞書・`created_at` が文字列・`format_version` 無し）。
    static let d1JSON = """
    {
      "conversion_version" : "d1-text-mlx-q8/1",
      "created_at" : "2026-10-09T03:04:05Z",
      "files" : {
        "LICENSE" : { "bytes" : 10, "sha256" : "\(sha)" },
        "config.json" : { "bytes" : 1200, "sha256" : "\(sha)" },
        "model.safetensors" : { "bytes" : 2900000000, "sha256" : "\(sha)" }
      },
      "quantization" : { "bits" : 8, "group_size" : 64, "mode" : "affine" },
      "repo" : "LiquidAI/d1-3B",
      "revision" : "051bcc464b01b9f92942b364d9586b0ef5912432",
      "source" : { "model.safetensors" : "50e03317847caf6df9a9aee27ed40f20554a86a21e60d1d47ba41a422b546c0c" },
      "tensor_count" : 321
    }
    """

    /// WhisperModelPreparer.writeManifest が書く形。
    static let whisperJSON = """
    {
      "created_at" : "2026-10-09T03:04:05Z",
      "files" : [
        { "path" : "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930/config.json", "sha256" : "\(sha)", "size" : 5 },
        { "path" : "models/openai/whisper-large-v3/tokenizer.json", "sha256" : "\(sha)", "size" : 7 }
      ],
      "format_version" : 1,
      "prepared_with" : "cc-models WhisperModelPreparer / WhisperKit 1.1.0",
      "repo" : "argmaxinc/whisperkit-coreml",
      "revision" : "0f63a7800b00dd0226abd051b906c246e1907482",
      "tokenizer_repo" : "openai/whisper-large-v3",
      "tokenizer_revision" : "06f233fe06e710322aca913c1bc4249a0d71fce1",
      "variant" : "openai_whisper-large-v3-v20240930"
    }
    """

    /// EmbeddingModelPreparer が書く形。
    static let embeddingJSON = """
    {
      "base_model" : "google/embeddinggemma-2",
      "compiled_on" : "Version 27.0.1 (Build 26A434)",
      "created_at" : "2026-10-10T12:17:19Z",
      "files" : [ { "path" : "embeddings.bf16", "sha256" : "\(sha)", "size" : 100 } ],
      "format_version" : 1,
      "license" : "Apache-2.0",
      "preparation_version" : "embeddinggemma-2-coreml/1",
      "prepared_with" : "cc-models EmbeddingModelPreparer",
      "repo" : "FluidInference/embeddinggemma-2-coreml",
      "revision" : "3f978dd",
      "source_files" : [ { "path" : "embeddings.bf16", "sha256" : "\(sha)", "size" : 100 } ]
    }
    """

    func testD1JSONReadsAsBothTypes() throws {
        let data = Data(Self.d1JSON.utf8)
        let concrete = try JSONDecoder().decode(D1ModelManifest.self, from: data)  // 型エイリアス経由（CCModels）
        XCTAssertEqual(concrete.tensorCount, 321)
        XCTAssertEqual(concrete.files["model.safetensors"]?.bytes, 2_900_000_000)

        let m = try ModelManifest.decode(data, slot: .d1)
        XCTAssertEqual(m, .d1(concrete))
        XCTAssertEqual(m.slot, .d1)
        XCTAssertEqual(m.repo, "LiquidAI/d1-3B")
        XCTAssertEqual(m.preparationVersion, "d1-text-mlx-q8/1")
        XCTAssertEqual(m.createdAt, ISO8601DateFormatter().date(from: "2026-10-09T03:04:05Z"))
        XCTAssertEqual(m.files.map(\.path), ["LICENSE", "config.json", "model.safetensors"])
        XCTAssertEqual(m.totalBytes, 2_900_001_210)
        // 書き直しても読める（形が変わらない）
        XCTAssertEqual(try ModelManifest.decode(m.encoded(), slot: .d1), m)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: m.encoded()) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["conversion_version", "created_at", "files", "quantization", "repo", "revision",
                                   "source", "tensor_count"])
    }

    func testWhisperJSONReadsAsBothTypes() throws {
        let data = Data(Self.whisperJSON.utf8)
        let concrete = try WhisperModelManifest.decode(data)
        XCTAssertEqual(concrete.variant, "openai_whisper-large-v3-v20240930")
        let file: WhisperModelManifest.File = concrete.files[0]
        let shared: ModelManifestFile = file  // File は共通型のエイリアス
        XCTAssertEqual(shared.size, 5)

        let m = try ModelManifest.decode(data, slot: .whisper)
        XCTAssertEqual(m, .whisper(concrete))
        XCTAssertEqual(m.revision, WhisperModelPreparer.pinnedModelRevision)
        XCTAssertEqual(m.files.count, 2)
        XCTAssertEqual(try ModelManifest.decode(m.encoded(), slot: .whisper), m)
    }

    func testEmbeddingJSONReadsAsBothTypes() throws {
        let data = Data(Self.embeddingJSON.utf8)
        let concrete = try EmbeddingModelManifest.decode(data)
        XCTAssertEqual(concrete.sourceFiles.count, 1)
        let m = try ModelManifest.decode(data, slot: .embedding)
        XCTAssertEqual(m, .embedding(concrete))
        XCTAssertEqual(m.preparationVersion, "embeddinggemma-2-coreml/1")
        XCTAssertEqual(m.createdAt, ISO8601DateFormatter().date(from: "2026-10-10T12:17:19Z"))
        XCTAssertEqual(try ModelManifest.decode(m.encoded(), slot: .embedding), m)
    }

    /// 形式を取り違えたら読めない（黙って空の値にならない）。
    func testWrongSlotFails() {
        XCTAssertThrowsError(try ModelManifest.decode(Data(Self.d1JSON.utf8), slot: .whisper))
        XCTAssertThrowsError(try ModelManifest.decode(Data(Self.whisperJSON.utf8), slot: .d1))
    }

    /// `CC_MODELS_DIR`（開発用の置き場）に本物の manifest があれば読む（**読むだけ**。書き込まない）。
    /// `CC_MODELS_DIR` を指定したのにモデルのディレクトリが 1 つも無ければ失敗（`TestModelLocator` と同じ規則）。
    /// manifest の無いディレクトリ（開発用の unmanifested な置き場）は数えない。
    func testRealManifestsInModelsDirectory() throws {
        guard let dir = TestModelLocator.explicitModelsDir else {
            throw XCTSkip("CC_MODELS_DIR が無い")
        }
        let paths = CCPaths(dataRoot: FileManager.default.temporaryDirectory, modelsRoot: dir)
        let slotDirs = ModelSlot.allCases.filter { FileManager.default.fileExists(atPath: paths.modelDirectory($0).path) }
        if slotDirs.isEmpty {
            throw TestModelLocator.ExplicitModelMissing(description: "CC_MODELS_DIR=\(dir.path) にモデルのディレクトリが 1 つも無い")
        }
        var read = 0
        for slot in ModelSlot.allCases where FileManager.default.fileExists(atPath: paths.manifestURL(slot).path) {
            let m = try ModelManifest.load(slot, paths: paths)
            XCTAssertEqual(m.slot, slot)
            XCTAssertFalse(m.files.isEmpty, "\(slot)")
            XCTAssertTrue(m.files.allSatisfy { $0.sha256.count == 64 }, "\(slot)")
            read += 1
        }
        if read == 0 { throw XCTSkip("CC_MODELS_DIR に manifest.json が無い") }
    }
}

/// d1 の取得物の後片付け。
final class D1DownloadsCleanupTests: XCTestCase {
    func testRemoveDownloadsKeepsOtherModels() throws {
        let fm = FileManager.default
        let models = fm.temporaryDirectory.appendingPathComponent("ccmodels-d1dl-\(UUID().uuidString)/Models", isDirectory: true)
        defer { try? fm.removeItem(at: models.deletingLastPathComponent()) }
        let p = D1ModelPreparer(destination: models.appendingPathComponent("d1-3b-text-q8"))
        XCTAssertTrue(p.removeDownloadsAfterConversion)
        XCTAssertEqual(p.downloadsDirectory.lastPathComponent, ".downloads")

        let d1 = p.downloadsDirectory.appendingPathComponent("models/LiquidAI/d1-3B", isDirectory: true)
        let other = p.downloadsDirectory.appendingPathComponent("models/Other/x", isDirectory: true)
        for dir in [d1, other] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("w".utf8).write(to: d1.appendingPathComponent("model.safetensors"))
        try Data("o".utf8).write(to: other.appendingPathComponent("f"))

        p.removeDownloads()
        XCTAssertFalse(fm.fileExists(atPath: d1.path))
        XCTAssertFalse(fm.fileExists(atPath: d1.deletingLastPathComponent().path))  // 空の LiquidAI/ も消える
        XCTAssertTrue(fm.fileExists(atPath: other.appendingPathComponent("f").path))  // 他のモデルは残す

        try fm.removeItem(at: other.deletingLastPathComponent())
        try fm.createDirectory(at: d1, withIntermediateDirectories: true)
        p.removeDownloads()
        XCTAssertFalse(fm.fileExists(atPath: p.downloadsDirectory.path))  // 空になれば .downloads ごと消える
        XCTAssertTrue(fm.fileExists(atPath: models.path))
    }
}
