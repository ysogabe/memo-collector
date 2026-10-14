import ArgumentParser
import CCCore
import CCEmbedding
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

        // 状態が ready なら検索モデル（テキスト塔）を裏で読み込み始める（すぐ戻る。stdio の受付は待たせない）。
        let queryEmbedder = makeQueryEmbedder(paths: paths, store: store)
        await queryEmbedder.prewarm()
        let handlers = MCPToolHandlers(store: store, embedderResolver: { await queryEmbedder.resolve() })
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
/// ANE の初回コンパイルは実行ファイルごとに数分かかるため、cc-mcp では ANE を使わず **テキスト塔を CPU/GPU で**読む
/// （main 決定。クエリはテキストだけなので視覚塔は読まない）。読み込みは起動直後に裏で始め（`prewarm`）、
/// 検索が来たら最大 5 秒待ち、間に合わなければ部分一致（`fallback_reason: embedder_warming`）。
/// 次のときは使わず、search_captures は部分一致に切り替わる（`fallback_reason: embedder_unavailable`）:
/// - 埋め込みモデル（`EmbeddingGemma2Text.mlmodelc` など）が `CC_MODELS_DIR` / 既定のモデル置き場に無い
/// - アプリが書く索引の状態ファイル（`SearchIndexState`、データルートの `search-index.json`）が無い・ready でない・
///   シグネチャ（`CoreMLEmbedder.Configuration.indexSignature`）がこちらの設定と食い違う → 標準エラーに警告
func makeQueryEmbedder(paths: CCPaths = .resolve(), store: SQLiteRecordStore? = nil) -> WarmingQueryEmbedder {
    let modelDirectory = paths.modelDirectory(.embedding)
    return WarmingQueryEmbedder(stateURL: paths.searchIndexStateURL, readState: {
        if let store {
            do {
                if let active = try await store.activeGeneration() {
                    return SearchIndexState(indexSignature: active.pipeline.compatibilityKey, imageTokens: active.pipeline.imageTokens,
                                            dimension: active.pipeline.dimension, status: .ready, updatedAt: Date())
                }
                if try await store.targetGeneration() != nil { return nil }
            } catch { return nil }
        }
        return SearchIndexState.read(from: paths.searchIndexStateURL)
    }) { state in
        let required = ["EmbeddingGemma2Text.mlmodelc", "embeddings.bf16", "tokenizer.json"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path) }) else {
            return .reject("埋め込みモデルが無いので部分一致で検索する: \(modelDirectory.path)")
        }
        let configuration = CoreMLEmbedder.Configuration(
            modelDirectory: modelDirectory,
            imageTokens: ImageTokenBudget(rawValue: state.imageTokens) ?? .tokens280,
            textComputeUnits: .cpuAndGPU,
            visionComputeUnits: .cpuAndGPU,
            dimension: state.dimension
        )
        guard configuration.indexSignature == state.indexSignature else {
            return .reject("索引のシグネチャが食い違うのでベクトル検索を使わない（アプリ: \(state.indexSignature)、cc-mcp: \(configuration.indexSignature)）")
        }
        return .use(.init(
            key: configuration.indexSignature,
            make: { CoreMLEmbedder(configuration: configuration) },
            warm: { embedder in
                // テキスト塔だけ読み、初回推論まで済ませる。
                if let coreML = embedder as? CoreMLEmbedder { _ = try await coreML.prepare(includeVision: false) }
            }
        ))
    }
}
