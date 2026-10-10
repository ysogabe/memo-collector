import ArgumentParser
import CCCore
import CCMCP
import CCStore
import Foundation
import MCP

/// stdio MCP サーバー（Claude Code / Hermes から起動される）。
///
/// - データは `CCPaths.resolve()`（環境変数 `CC_DATA_DIR` を尊重）の SQLite を、アプリと同時に開く（WAL）。
/// - 標準出力は MCP のプロトコル専用。ログは標準エラーへ（注釈本文・秘密は出さない）。
@main
struct CCMCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cc-mcp",
        abstract: "Context Capture の記録を MCP で公開する（stdio）"
    )

    func run() async throws {
        let paths = CCPaths.resolve()
        // SQLiteRecordStore は DB が無ければ作ってしまうので、開く前に確かめる。
        guard FileManager.default.fileExists(atPath: paths.databaseURL.path) else {
            MCPLog.write("""
            データベースが見つからない: \(paths.databaseURL.path)
            Context Capture アプリを一度起動して記録を作るか、環境変数 \(CCPaths.dataDirEnvironmentKey) でデータの場所を指定してください。
            """)
            throw ExitCode(2)
        }

        let store: SQLiteRecordStore
        do {
            store = try SQLiteRecordStore(paths: paths)
        } catch {
            MCPLog.write("データベースを開けない: \(paths.databaseURL.path)（\(type(of: error))）")
            throw ExitCode(3)
        }

        let handlers = MCPToolHandlers(store: store, embedderProvider: makeEmbedderProvider())
        let server = ContextCaptureMCPServer(handlers: handlers)
        try await server.start(transport: StdioTransport())
        MCPLog.write("起動した（データ: \(paths.dataRoot.path)）")
        await server.waitUntilCompleted()
        await server.stop()
        MCPLog.write("終了した")
    }
}

/// 検索用の埋め込みモデルを作る唯一の場所。
///
/// ANE の初回コンパイルは実行ファイルごとに数分かかるため、cc-mcp では ANE を使わず CPU/GPU で、
/// 最初の検索時に遅延ロードする方針（main 決定）。埋め込みが無い間は search_captures が部分一致に切り替わる。
func makeEmbedderProvider() -> EmbedderProvider {
    // TODO(embedding): CoreMLEmbedder(computeUnits: .cpuAndGPU) を遅延生成
    return { nil }
}
