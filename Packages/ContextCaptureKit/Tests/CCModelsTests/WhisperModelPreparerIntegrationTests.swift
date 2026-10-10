import CCCore
import Foundation
import XCTest
@testable import CCModels

/// 実モデルを使うテスト。モデルが無ければ XCTSkip。**モデルの置き場には何も書かない**（スパイクの取得物は読み取り専用）。
final class WhisperModelPreparerIntegrationTests: XCTestCase {
    /// `CC_MODELS_DIR`（`<dir>/whisperkit/` または `<dir>/stt/whisperkit/`）→ 既定の保存先 → スパイクの取得物の順に探す。
    static func locateModel() -> WhisperModelPreparer? {
        var roots = [CCPaths.resolve().modelDirectory(.whisper)]
        if let env = ProcessInfo.processInfo.environment[CCPaths.modelsDirEnvironmentKey], !env.isEmpty {
            roots.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath).appendingPathComponent("stt/whisperkit"))
        }
        // .../Packages/ContextCaptureKit/Tests/CCModelsTests/<file> → リポジトリ（worktree）ルート
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        roots.append(repo.appendingPathComponent("spikes/runtime/models/stt/whisperkit"))
        // worktree なら本体の作業ツリー（.git ファイルの gitdir から辿る）
        if let text = try? String(contentsOf: repo.appendingPathComponent(".git"), encoding: .utf8),
           text.hasPrefix("gitdir:"),
           let range = text.range(of: "/.git/worktrees/") {
            let main = text.dropFirst("gitdir:".count)[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            roots.append(URL(fileURLWithPath: main).appendingPathComponent("spikes/runtime/models/stt/whisperkit"))
        }
        return roots.map { WhisperModelPreparer(root: $0) }.first { $0.missingRequiredFiles().isEmpty }
    }

    func testBuildManifestFromRealModelWithoutWriting() throws {
        guard let p = Self.locateModel() else { throw XCTSkip("WhisperKit のモデルが見つからない") }
        let hadManifest = FileManager.default.fileExists(atPath: p.manifestURL.path)
        let status = try p.verify(level: .size)
        if !hadManifest { XCTAssertEqual(status, .unmanifested) }

        let start = Date()
        let m = try p.buildManifest()
        let seconds = Date().timeIntervalSince(start)
        let total = m.files.reduce(Int64(0)) { $0 + $1.size }
        print(String(format: "[ccmodels] %@: %d files, %.2f GB, sha256 in %.1fs, revision=%@ tokenizer=%@",
                     p.root.path, m.files.count, Double(total) / 1e9, seconds, m.revision, m.tokenizerRevision))
        XCTAssertEqual(m.revision, WhisperModelPreparer.pinnedModelRevision)
        XCTAssertEqual(m.tokenizerRevision, WhisperModelPreparer.pinnedTokenizerRevision)
        XCTAssertGreaterThan(total, 1_000_000_000)
        for name in WhisperModelPreparer.requiredModelNames {
            XCTAssertTrue(m.files.contains { $0.path.hasSuffix("\(name).mlmodelc/coremldata.bin") }, name)
        }
        XCTAssertTrue(m.files.contains { $0.path == "models/openai/whisper-large-v3/tokenizer.json" })
        // 書いていない
        XCTAssertEqual(FileManager.default.fileExists(atPath: p.manifestURL.path), hadManifest)
    }

    func testWarmUpLoadsModel() async throws {
        guard let p = Self.locateModel() else { throw XCTSkip("WhisperKit のモデルが見つからない") }
        let r = try await p.warmUp()
        print(String(format: "[ccmodels] warm-up %.1fs", r.loadSeconds))
        XCTAssertGreaterThan(r.loadSeconds, 0)
    }

    /// 取得経路の確認（`CC_NETWORK_TESTS=1` のときだけ。小さい tiny（約 75MB）を一時ディレクトリへ取る）。
    func testPrepareDownloadsTinyVariant() async throws {
        guard ProcessInfo.processInfo.environment["CC_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("CC_NETWORK_TESTS=1 のときだけ走る（ネットワークから約 75MB 取得する）")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ccmodels-net-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = WhisperModelPreparer(root: tmp.appendingPathComponent("whisperkit"), variant: "openai_whisper-tiny")

        let first = try await p.prepare()
        guard case .prepared(let m) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(m.revision, WhisperModelPreparer.pinnedModelRevision)
        XCTAssertEqual(m.tokenizerRevision, WhisperModelPreparer.pinnedTokenizerRevision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.manifestURL.path))

        // 2 回目は検証だけ
        let second = try await p.prepare()
        XCTAssertEqual(second, .alreadyPrepared(m))

        // 壊したファイルは取り直される
        let config = p.modelFolder.appendingPathComponent("config.json")
        try Data("broken".utf8).write(to: config)
        guard case .mismatched = try p.verify() else { return XCTFail() }
        guard case .prepared = try await p.prepare() else { return XCTFail() }
        guard case .ready = try p.verify() else { return XCTFail() }

        let r = try await p.warmUp()
        print(String(format: "[ccmodels] tiny warm-up %.1fs", r.loadSeconds))
    }
}
