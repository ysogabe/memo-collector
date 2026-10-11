import CCCore
import Foundation
import XCTest

/// 実モデルを使うテストのモデル探索（**全テストターゲットで同じ規則**）。
///
/// このファイルは同じ内容で次の 5 か所に置いてある（SwiftPM のテストターゲットはソースを共有できず、Package.swift は
/// 編集しない約束のため）。変えるときは全部そろえること:
/// `Tests/CCSTTTests/` `Tests/CCModelsTests/` `Tests/CCIntentTests/` `Tests/CCEmbeddingTests/` `Tests/CCTriageTests/`
///
/// 規則:
/// - `CC_MODELS_DIR` が**指定されている**ときは、その下（`<dir>/<ModelSlot.directoryName>`。Whisper は
///   スパイクの配置 `<dir>/stt/whisperkit` も）**だけ**を探す。見つからなければ `ExplicitModelMissing` を投げて
///   **テストを失敗させる**（指定した置き場にモデルが無いのに黙って skip して「通った」ように見せない）。
///   既定の置き場・HF キャッシュ・スパイクのパスへは逃げない。
/// - **未指定**のときは、既定の置き場（`~/Library/Application Support/ContextCapture/Models/<slot>`。存在を見るだけで
///   書き込まない）→ スロットごとのスパイクのパス（この worktree → 本体の作業ツリーの順）を探し、無ければ nil
///   （呼び出し側が `XCTSkip`）。
enum TestModelLocator {
    /// `CC_MODELS_DIR` が指定されているのに、そこに必要なモデルが無い。
    struct ExplicitModelMissing: Error, CustomStringConvertible {
        let description: String
    }

    /// スロットごとのスパイクのパス（リポジトリルートからの相対。未指定のときだけ使う）。
    static func spikeSubpaths(_ slot: ModelSlot) -> [String] {
        switch slot {
        case .whisper: return ["spikes/runtime/models/stt/whisperkit"]
        case .embedding: return ["spikes/fluid/models/swift-dir"]
        case .d1: return []
        }
    }

    /// `CC_MODELS_DIR`（空なら未指定）。
    static var explicitModelsDir: URL? {
        guard let raw = ProcessInfo.processInfo.environment[CCPaths.modelsDirEnvironmentKey], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// リポジトリ（またはこの worktree）のルート。`.../Packages/ContextCaptureKit/Tests/<Target>/<file>` から 5 つ上。
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    /// git worktree なら本体の作業ツリーのルート（`.git` ファイルの gitdir から辿る）。worktree でなければ nil。
    static var mainWorktreeRoot: URL? {
        let dotGit = repoRoot.appendingPathComponent(".git")
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
        let gitdir = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return URL(fileURLWithPath: String(gitdir[..<range.lowerBound]), isDirectory: true)
    }

    /// 探す候補（順に）と、`CC_MODELS_DIR` 指定かどうか。
    static func candidates(_ slot: ModelSlot) -> (dirs: [URL], explicit: URL?) {
        if let dir = explicitModelsDir {
            var dirs = [dir.appendingPathComponent(slot.directoryName, isDirectory: true)]
            if slot == .whisper { dirs.append(dir.appendingPathComponent("stt/whisperkit", isDirectory: true)) }
            return (dirs, dir)
        }
        var dirs = [CCPaths.resolve(environment: [:]).modelDirectory(slot)]
        for root in [repoRoot, mainWorktreeRoot].compactMap({ $0 }) {
            for sub in spikeSubpaths(slot) { dirs.append(root.appendingPathComponent(sub, isDirectory: true)) }
        }
        return (dirs, nil)
    }

    /// モデルのディレクトリを探す。`isComplete` が true を返す最初の候補。
    /// `CC_MODELS_DIR` 指定で見つからなければ throw（テストは失敗）、未指定で見つからなければ nil。
    static func locate(_ slot: ModelSlot, isComplete: (URL) -> Bool) throws -> URL? {
        let (dirs, explicit) = candidates(slot)
        if let found = dirs.first(where: isComplete) { return found }
        if let explicit {
            throw ExplicitModelMissing(description: """
                CC_MODELS_DIR=\(explicit.path) が指定されているのに \(slot.rawValue) のモデルが見つからない \
                （探した場所: \(dirs.map(\.path).joined(separator: ", "))）
                """)
        }
        return nil
    }

    /// `locate` の nil を `XCTSkip` にする。
    static func require(_ slot: ModelSlot, isComplete: (URL) -> Bool) throws -> URL {
        guard let url = try locate(slot, isComplete: isComplete) else {
            let searched = candidates(slot).dirs.map(\.path).joined(separator: ", ")
            throw XCTSkip("\(slot.rawValue) のモデルが無い（CC_MODELS_DIR 未指定。探した場所: \(searched)）")
        }
        return url
    }
}
