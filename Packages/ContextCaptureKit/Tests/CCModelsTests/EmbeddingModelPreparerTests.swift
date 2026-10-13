import CryptoKit
import XCTest
@testable import CCCore
@testable import CCModels

final class EmbeddingModelPreparerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("emb-prep-\(UUID().uuidString)", isDirectory: true)
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

    /// 読み込みに要るファイルをダミーで置き、manifest をその場で作る。
    private func makeFakeInstalled(_ dest: URL, revision: String = EmbeddingModelPreparer.revision) throws {
        let files = ["EmbeddingGemma2Text.mlmodelc/coremldata.bin": "t", "EmbeddingGemma2Vision.mlmodelc/coremldata.bin": "v",
                     "embeddings.bf16": "e", "position_embeddings.f16": "p", "tokenizer.json": "{}", "LICENSE": "L"]
        for (k, v) in files { try write(v, k, in: dest) }
        let m = EmbeddingModelManifest(
            formatVersion: 1, repo: EmbeddingModelPreparer.repoId, revision: revision, baseModel: "google/embeddinggemma-2",
            license: "Apache-2.0", preparationVersion: EmbeddingModelPreparer.preparationVersion, preparedWith: "test",
            compiledOn: "test", createdAt: Date(timeIntervalSince1970: 1_760_000_000), sourceFiles: [],
            files: files.keys.sorted().map { .init(path: $0, size: Int64(files[$0]!.utf8.count), sha256: sha(files[$0]!)) })
        try m.encoded().write(to: dest.appendingPathComponent("manifest.json"))
    }

    func testPinnedSourcesCoverTextAndVisionButNotAudio() {
        let paths = EmbeddingModelPreparer.pinnedSourceFiles.map(\.path)
        XCTAssertEqual(paths.count, 11)
        XCTAssertFalse(paths.contains { $0.contains("Audio") })
        for p in EmbeddingModelPreparer.packages { XCTAssertTrue(paths.contains("\(p).mlpackage/Manifest.json")) }
        for f in EmbeddingModelPreparer.copiedFiles { XCTAssertTrue(paths.contains(f)) }
        XCTAssertTrue(EmbeddingModelPreparer.pinnedSourceFiles.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
        XCTAssertEqual(EmbeddingModelPreparer.revision.count, 40)
        XCTAssertEqual(EmbeddingModelPreparer(paths: CCPaths(dataRoot: tmp, modelsRoot: tmp)).destination.lastPathComponent,
                       "embeddinggemma-2")
    }

    func testLicenseAndNotice() {
        XCTAssertTrue(EmbeddingModelLicense.apache2.contains("Apache License"))
        XCTAssertTrue(EmbeddingModelLicense.apache2.contains("Version 2.0, January 2004"))
        XCTAssertTrue(EmbeddingModelLicense.apache2.contains("END OF TERMS AND CONDITIONS"))
        XCTAssertTrue(EmbeddingModelPreparer.notice.contains("google/embeddinggemma-2"))
        XCTAssertTrue(EmbeddingModelPreparer.notice.contains(EmbeddingModelPreparer.revision))
    }

    func testVerifyStatuses() throws {
        let dest = tmp.appendingPathComponent("embeddinggemma-2")
        let p = EmbeddingModelPreparer(destination: dest)
        guard case .missing(let m) = try p.verify() else { return XCTFail("expected missing") }
        XCTAssertEqual(Set(m), Set(EmbeddingModelPreparer.requiredFiles))

        try makeFakeInstalled(dest)
        guard case .ready(let manifest) = try p.verify() else { return XCTFail("expected ready") }
        XCTAssertEqual(manifest.revision, EmbeddingModelPreparer.revision)

        // 中身の改変（大きさ同じ）は sha256 でだけ分かる
        try Data("x".utf8).write(to: dest.appendingPathComponent("embeddings.bf16"))
        guard case .ready = try p.verify(level: .size) else { return XCTFail("size-only should pass") }
        XCTAssertEqual(try p.verify(level: .sha256), .mismatched(["embeddings.bf16"]))
        try Data("e".utf8).write(to: dest.appendingPathComponent("embeddings.bf16"))

        // manifest に無いファイルが足された
        try write("extra", "EmbeddingGemma2Text.mlmodelc/extra.bin", in: dest)
        XCTAssertEqual(try p.verify(), .mismatched(["EmbeddingGemma2Text.mlmodelc/extra.bin"]))
        try FileManager.default.removeItem(at: dest.appendingPathComponent("EmbeddingGemma2Text.mlmodelc/extra.bin"))

        // manifest が無い
        try FileManager.default.removeItem(at: dest.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try p.verify(), .unmanifested)

        // 別 revision の manifest
        try makeFakeInstalled(dest, revision: String(repeating: "0", count: 40))
        XCTAssertEqual(try p.verify(), .mismatched(["manifest.json"]))
    }

    func testAlreadyPreparedDoesNothing() async throws {
        let dest = tmp.appendingPathComponent("embeddinggemma-2")
        try makeFakeInstalled(dest)
        let before = try Data(contentsOf: dest.appendingPathComponent("manifest.json"))
        guard case .alreadyPrepared = try await EmbeddingModelPreparer(destination: dest).prepare() else {
            return XCTFail("expected alreadyPrepared")
        }
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("manifest.json")), before)
    }

    func testManifestRoundTrip() throws {
        let m = EmbeddingModelManifest(
            formatVersion: 1, repo: "r", revision: "v", baseModel: "b", license: "Apache-2.0", preparationVersion: "p/1",
            preparedWith: "w", compiledOn: "macOS", createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            sourceFiles: [.init(path: "a/b", size: 1, sha256: "00")], files: [.init(path: "c", size: 2, sha256: "11")])
        let data = try m.encoded()
        let s = String(decoding: data, as: UTF8.self)
        for key in ["format_version", "source_files", "preparation_version", "created_at", "base_model", "compiled_on"] {
            XCTAssertTrue(s.contains("\"\(key)\""), key)
        }
        XCTAssertTrue(s.contains("2025-10-09T08:53:20Z"))
        XCTAssertEqual(try EmbeddingModelManifest.decode(data), m)
    }

    /// sha256 が合わない元ファイルでは何も置かずに失敗する（既存の置き場も壊さない）。
    func testChecksumMismatchLeavesDestinationUntouched() async throws {
        let src = tmp.appendingPathComponent("src"), dest = tmp.appendingPathComponent("models/embeddinggemma-2")
        try write("not the real config", "config.json", in: src)
        try write("keep", "keep.txt", in: dest)
        var p = EmbeddingModelPreparer(destination: dest)
        p.sourceFiles = [.init(path: "config.json", size: 19, sha256: String(repeating: "a", count: 64))]
        do {
            _ = try await p.prepare(source: src)
            XCTFail("should throw")
        } catch let EmbeddingPrepareError.checksumMismatch(path, _, actual) {
            XCTAssertEqual(path, "config.json")
            XCTAssertEqual(actual, sha("not the real config"))
        }
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("keep.txt"), encoding: .utf8), "keep")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["embeddinggemma-2"], "no partial directory should remain")
    }

    /// 取得（file:// で代用）: 入れ子のパスを作り、既に sha256 が合うファイルは取り直さない。
    func testDownloadIntoNestedPathsAndSkipsVerified() async throws {
        let remote = tmp.appendingPathComponent("remote", isDirectory: true), local = tmp.appendingPathComponent("dl")
        try write("hello", "A.mlpackage/Data/x.bin", in: remote)
        try write("cfg", "config.json", in: remote)
        var p = EmbeddingModelPreparer(destination: tmp.appendingPathComponent("embeddinggemma-2"))
        p.baseURL = remote
        p.sourceFiles = [.init(path: "A.mlpackage/Data/x.bin", size: 5, sha256: sha("hello")),
                         .init(path: "config.json", size: 3, sha256: sha("cfg"))]
        try await p.download(into: local)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("A.mlpackage/Data/x.bin"), encoding: .utf8), "hello")
        // 取得元を消しても、手元が正しければ取り直さない（失敗しない）
        try FileManager.default.removeItem(at: remote)
        try await p.download(into: local)
    }

    /// 実物（スパイクが取得した revision 3f978dd）から作る結合テスト。無ければ skip。
    func testPrepareFromSpikeSnapshot() async throws {
        let candidates = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spikes/fluid/models/embeddinggemma-2-coreml"),
            URL(fileURLWithPath: "/Users/yoshio/works/60-misc/memo-collector/spikes/fluid/models/embeddinggemma-2-coreml"),
        ]
        guard let src = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("embeddings.bf16").path) })
        else { throw XCTSkip("spike snapshot of embeddinggemma-2-coreml not found") }
        let dest = tmp.appendingPathComponent("models/embeddinggemma-2")
        let p = EmbeddingModelPreparer(destination: dest)
        let t = Date()
        guard case .prepared(let m) = try await p.prepare(source: src) else { return XCTFail("expected prepared") }
        print(String(format: "[metrics] embedding prepare from local snapshot: %.1f s, %d files", Date().timeIntervalSince(t), m.files.count))
        XCTAssertEqual(m.sourceFiles.map(\.sha256), EmbeddingModelPreparer.pinnedSourceFiles.map(\.sha256))
        let names = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        XCTAssertEqual(names, ["EmbeddingGemma2Text.mlmodelc", "EmbeddingGemma2Vision.mlmodelc", "LICENSE", "NOTICE.txt", "README.md",
                               "config.json", "embeddings.bf16", "manifest.json", "position_embeddings.f16", "tokenizer.json"])
        XCTAssertTrue(m.files.contains { $0.path.hasPrefix("EmbeddingGemma2Text.mlmodelc/") })
        guard case .ready = try p.verify(level: .sha256) else { return XCTFail("expected ready") }
        guard case .alreadyPrepared = try await p.prepare(source: src) else { return XCTFail("expected alreadyPrepared") }
    }
}
