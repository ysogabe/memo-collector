import CCCore
import Foundation
import XCTest
@testable import CCModels

final class WhisperModelPreparerTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ccmodels-whisper-\(UUID().uuidString)/whisperkit", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root.deletingLastPathComponent())
    }

    func write(_ text: String, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Hub がダウンロードしたのと同じ形の小さな偽モデルを作る。
    func makeFakeModel(_ p: WhisperModelPreparer) throws {
        let v = "models/argmaxinc/whisperkit-coreml/\(p.variant)"
        for name in WhisperModelPreparer.requiredModelNames {
            try write("\(name)-data", "\(v)/\(name).mlmodelc/coremldata.bin")
            try write("\(name)-weights", "\(v)/\(name).mlmodelc/weights/weight.bin")
        }
        try write("{}", "\(v)/config.json")
        try write("{\"model\":\"tok\"}", "models/openai/whisper-large-v3/tokenizer.json")
        try write("{}", "models/openai/whisper-large-v3/tokenizer_config.json")
        // Hub の .metadata（1 行目が commit）
        let meta = "models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(p.variant)"
        try write("0f63a7800b00dd0226abd051b906c246e1907482\netag\n1\n", "\(meta)/config.json.metadata")
        try write("0f63a7800b00dd0226abd051b906c246e1907482\netag\n1\n", "\(meta)/TextDecoder.mlmodelc/coremldata.bin.metadata")
        try write("06f233fe06e710322aca913c1bc4249a0d71fce1\netag\n1\n",
                  "models/openai/whisper-large-v3/.cache/huggingface/download/tokenizer.json.metadata")
        try write("junk", "models/openai/whisper-large-v3/.DS_Store")
    }

    func testPathsFollowCCPaths() {
        let paths = CCPaths(dataRoot: root, modelsRoot: root.deletingLastPathComponent())
        let p = WhisperModelPreparer(paths: paths)
        XCTAssertEqual(p.root, paths.modelDirectory(.whisper))
        XCTAssertEqual(p.manifestURL, paths.manifestURL(.whisper))
        XCTAssertTrue(p.modelFolder.path.hasSuffix("whisperkit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930"))
        XCTAssertTrue(p.tokenizerFolder.path.hasSuffix("whisperkit/models/openai/whisper-large-v3"))
    }

    func testSHA256() throws {
        try write("abc", "x.txt")
        XCTAssertEqual(try WhisperModelManifest.sha256Hex(of: root.appendingPathComponent("x.txt")),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testManifestRoundTripUsesSnakeCaseKeys() throws {
        let m = WhisperModelManifest(
            repo: "argmaxinc/whisperkit-coreml", variant: "v", revision: "r", tokenizerRepo: "openai/whisper-large-v3",
            tokenizerRevision: "t", preparedWith: "test", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            files: [.init(path: "models/a", size: 3, sha256: "00")])
        let data = try m.encoded()
        let json = String(decoding: data, as: UTF8.self)
        for key in ["\"format_version\"", "\"tokenizer_revision\"", "\"created_at\"", "\"sha256\"", "\"2026-09-21T"] {
            XCTAssertTrue(json.contains(key), "\(key) in \(json)")
        }
        XCTAssertEqual(try WhisperModelManifest.decode(data), m)
    }

    func testVerifyLifecycle() throws {
        let p = WhisperModelPreparer(root: root)
        // 空 → missing
        guard case .missing(let missing) = try p.verify() else { return XCTFail() }
        XCTAssertEqual(missing.count, 4)

        try makeFakeModel(p)
        // ファイルはあるが manifest なし。verify は何も書かない
        XCTAssertEqual(try p.verify(), .unmanifested)
        XCTAssertFalse(fm.fileExists(atPath: p.manifestURL.path))

        let m = try p.buildManifest(createdAt: Date(timeIntervalSince1970: 1_790_000_000.7))
        XCTAssertEqual(m.revision, "0f63a7800b00dd0226abd051b906c246e1907482")
        XCTAssertEqual(m.tokenizerRevision, "06f233fe06e710322aca913c1bc4249a0d71fce1")
        XCTAssertEqual(m.createdAt, Date(timeIntervalSince1970: 1_790_000_000))
        // .cache と .DS_Store は載せない
        XCTAssertEqual(m.files.count, 3 * 2 + 1 + 2)
        XCTAssertFalse(m.files.contains { $0.path.contains(".cache") || $0.path.contains(".DS_Store") })
        XCTAssertEqual(m.files.map(\.path), m.files.map(\.path).sorted())
        XCTAssertTrue(m.files.allSatisfy { $0.path.hasPrefix("models/") && $0.sha256.count == 64 })

        try p.writeManifest(m)
        XCTAssertEqual(try p.verify(), .ready(m))
        XCTAssertEqual(try p.verify(level: .size), .ready(m))

        let decoder = "models/argmaxinc/whisperkit-coreml/\(p.variant)/TextDecoder.mlmodelc/weights/weight.bin"
        // サイズが変わる → サイズだけの検証でも検出
        try write("TextDecoder-weights-longer", decoder)
        XCTAssertEqual(try p.verify(level: .size), .mismatched([decoder]))
        // 同じ長さで中身だけ変える（"TextDecoder-weights" と同じ 19 文字）→ sha256 でだけ検出
        try write("TextDecoder-weightX", decoder)
        XCTAssertEqual(try p.verify(level: .size), .ready(m))
        XCTAssertEqual(try p.verify(level: .sha256), .mismatched([decoder]))

        // 取り直し用の削除: ファイルと .metadata を消す
        try p.removeDownloaded("models/argmaxinc/whisperkit-coreml/\(p.variant)/TextDecoder.mlmodelc/coremldata.bin")
        XCTAssertFalse(fm.fileExists(atPath: p.modelFolder.appendingPathComponent("TextDecoder.mlmodelc/coremldata.bin").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(p.variant)/TextDecoder.mlmodelc/coremldata.bin.metadata").path))
        guard case .missing = try p.verify() else { return XCTFail() }
    }

    func testExtraFileIsMismatch() throws {
        let p = WhisperModelPreparer(root: root)
        try makeFakeModel(p)
        try p.writeManifest(try p.buildManifest())
        try write("new", "models/argmaxinc/whisperkit-coreml/\(p.variant)/extra.bin")
        XCTAssertEqual(try p.verify(level: .size), .mismatched(["models/argmaxinc/whisperkit-coreml/\(p.variant)/extra.bin"]))
    }

    func testUnknownRevisionWhenMetadataMissing() throws {
        let p = WhisperModelPreparer(root: root)
        try makeFakeModel(p)
        try fm.removeItem(at: root.appendingPathComponent("models/openai/whisper-large-v3/.cache"))
        XCTAssertEqual(try p.buildManifest().tokenizerRevision, "unknown")
    }

    func testWarmUpWithoutModelThrows() async {
        let p = WhisperModelPreparer(root: root)
        do {
            _ = try await p.warmUp()
            XCTFail("throw されるはず")
        } catch let e as WhisperModelPreparerError {
            guard case .downloadIncomplete = e else { return XCTFail("\(e)") }
        } catch {
            XCTFail("\(error)")
        }
    }
}

/// manifest の無い既存モデル（`.unmanifested`）を取り直さずに採用する経路。
final class WhisperAdoptExistingTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ccmodels-adopt-\(UUID().uuidString)/whisperkit", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ text: String, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makeFiles(_ p: WhisperModelPreparer, modelCommit: String?) throws {
        let v = "models/argmaxinc/whisperkit-coreml/\(p.variant)"
        for name in WhisperModelPreparer.requiredModelNames { try write("\(name)", "\(v)/\(name).mlmodelc/coremldata.bin") }
        try write("{}", "models/openai/whisper-large-v3/tokenizer.json")
        if let modelCommit {
            try write("\(modelCommit)\netag\n1\n",
                      "models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(p.variant)/AudioEncoder.mlmodelc/coremldata.bin.metadata")
        }
    }

    /// `prepare()` は .unmanifested でネットワークに行かず manifest だけ作る（取得すると一時ディレクトリでは失敗する／遅い）。
    func testPrepareAdoptsUnmanifestedFilesWithoutNetwork() async throws {
        let p = WhisperModelPreparer(root: root)
        try makeFiles(p, modelCommit: nil)  // スパイクの取得物のように .metadata が無い
        XCTAssertEqual(try p.verify(level: .size), .unmanifested)
        XCTAssertTrue(p.canAdoptExisting())

        var stages: [String] = []
        let lock = NSLock()
        let outcome = try await p.prepare { stage, _ in lock.lock(); stages.append(stage); lock.unlock() }
        guard case .prepared(let m) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(Set(stages), ["manifest"])  // model / tokenizer の取得は無い
        XCTAssertEqual(m.revision, "unknown")
        XCTAssertEqual(m.files.count, 4)
        XCTAssertTrue(m.files.allSatisfy { !$0.path.hasPrefix("/") })
        guard case .ready = try p.verify(level: .sha256) else { return XCTFail() }
        // 2 回目は何もしない
        let again = try await p.prepare()
        XCTAssertEqual(again, .alreadyPrepared(m))
    }

    func testAdoptExistingRecordsPinnedRevision() throws {
        let p = WhisperModelPreparer(root: root)
        try makeFiles(p, modelCommit: WhisperModelPreparer.pinnedModelRevision)
        XCTAssertTrue(p.canAdoptExisting())
        guard case .prepared(let m) = try p.adoptExisting() else { return XCTFail() }
        XCTAssertEqual(m.revision, WhisperModelPreparer.pinnedModelRevision)
    }

    func testDoesNotAdoptOtherCommitOrIncompleteFiles() throws {
        let p = WhisperModelPreparer(root: root)
        try makeFiles(p, modelCommit: "deadbeef")
        XCTAssertFalse(p.canAdoptExisting())  // prepare() は固定 revision で取り直す側へ行く

        let q = WhisperModelPreparer(root: root.deletingLastPathComponent().appendingPathComponent("empty"))
        XCTAssertFalse(q.canAdoptExisting())
        XCTAssertThrowsError(try q.adoptExisting())
    }
}
