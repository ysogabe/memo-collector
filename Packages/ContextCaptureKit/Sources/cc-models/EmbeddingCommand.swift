import ArgumentParser
import CCCore
import CCModels
import Foundation

/// `cc-models prepare embedding`（グループ `Prepare` は CCModelsCommand.swift）。
///
/// ANE の温めはしない: ANE のコンパイル結果は実行バイナリ単位でキャッシュされるので、ここで温めてもアプリでは効かない。
/// アプリ本体が起動後に `CoreMLEmbedder.prepare()` を呼んで温める。
struct PrepareEmbeddingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embedding",
        abstract: "EmbeddingGemma 2 Core ML 版（revision 3f978dd、約 0.9GB）を取得・sha256 照合・コンパイルする（揃っていれば検証のみ。ANE の温めはアプリ側）"
    )

    @Option(help: "元ファイルのディレクトリ（HF リポジトリと同じ構成）。省略時は HF から取得")
    var source: String?

    @Option(help: "出力先。省略時は CCPaths の Models/embeddinggemma-2/")
    var output: String?

    @Flag(help: "揃っていても作り直す")
    var force = false

    @Flag(help: "作らずに manifest と突き合わせるだけ（sha256）")
    var verifyOnly = false

    func run() async throws {
        let dest = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? CCPaths.resolve().modelDirectory(.embedding)
        let p = EmbeddingModelPreparer(destination: dest)
        print("embedding: \(dest.path)")
        if verifyOnly {
            switch try p.verify(level: .sha256) {
            case .ready(let m): print("ok: \(m.repo) @ \(m.revision.prefix(7)) (\(m.files.count) files)")
            case .missing(let paths): print("missing: \(paths.joined(separator: ", "))"); throw ExitCode(1)
            case .unmanifested: print("files present but no manifest.json (run: cc-models prepare embedding)"); throw ExitCode(1)
            case .mismatched(let paths): print("mismatched: \(paths.joined(separator: ", "))"); throw ExitCode(1)
            }
            return
        }
        let src = source.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        let t0 = Date()
        let lock = NSLock()
        nonisolated(unsafe) var last: [String: Int] = [:]
        let outcome = try await p.prepare(source: src, force: force) { stage, fraction in
            let step = Int((fraction * 10).rounded(.down))
            lock.lock(); defer { lock.unlock() }
            guard last[stage] != step else { return }
            last[stage] = step
            print("  \(stage): \(step * 10)%")
        }
        switch outcome {
        case .alreadyPrepared(let m):
            print("already prepared: \(m.repo) @ \(m.revision.prefix(7)) (\(m.files.count) files, sha256 verified)")
        case .prepared(let m):
            print(String(format: "prepared: %@ @ %@ (%d files) in %.0f s → %@", m.repo, String(m.revision.prefix(7)),
                         m.files.count, Date().timeIntervalSince(t0), p.manifestURL.path))
        }
    }
}
