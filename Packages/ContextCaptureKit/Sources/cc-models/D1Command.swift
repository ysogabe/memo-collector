import ArgumentParser
import CCCore
import CCModels
import Foundation

/// `cc-models prepare d1`（グループ `Prepare` は CCModelsCommand.swift）。
struct PrepareD1: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "d1",
        abstract: "LiquidAI/d1-3B（revision 051bcc4）から MLX 8bit の言語モデル部を作る（数分・メモリ数 GB）"
    )

    @Option(help: "元モデルのディレクトリ（HF snapshot と同じ構成）。省略時は Python の HF キャッシュ → HF から取得")
    var source: String?

    @Option(help: "出力先。省略時は CCPaths の Models/d1-3b-text-q8/")
    var output: String?

    @Flag(help: "変換後に manifest の sha256 を検証する")
    var verify = false

    @Flag(help: "HF から取得した元モデル（Models/.downloads/、約 5.8GB）を変換後も残す（既定は消す）")
    var keepDownloads = false

    func run() async throws {
        let dest = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? CCPaths.resolve().modelDirectory(.d1)
        var preparer = D1ModelPreparer(destination: dest)
        preparer.removeDownloadsAfterConversion = !keepDownloads
        let src = source.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        let t0 = Date()
        let m = try await preparer.prepare(source: src) { f, msg in
            print(String(format: "[%3.0f%%] %@", f * 100, msg))
        }
        print("wrote \(dest.path) (\(m.tensorCount) tensors, \(String(format: "%.0f", Date().timeIntervalSince(t0))) s)")
        if verify {
            let bad = try D1ModelPreparer.verify(directory: dest)
            if !bad.isEmpty { throw ValidationError("sha256 mismatch: \(bad.joined(separator: ", "))") }
            print("verified")
        }
    }
}
