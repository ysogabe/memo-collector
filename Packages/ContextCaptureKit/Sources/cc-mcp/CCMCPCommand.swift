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

        let handlers = MCPToolHandlers(store: store, embedderProvider: makeEmbedderProvider(paths: paths))
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
/// ANE の初回コンパイルは実行ファイルごとに数分かかるため、cc-mcp では ANE を使わず **テキスト塔を CPU/GPU で**、
/// 最初の検索時に遅延ロードする（main 決定。クエリはテキストだけなので視覚塔は読まない）。
/// 次のときは nil を返し、search_captures は部分一致に切り替わる（`fallback_reason: embedder_unavailable`）:
/// - 埋め込みモデル（`EmbeddingGemma2Text.mlmodelc` など）が `CC_MODELS_DIR` / 既定のモデル置き場に無い
/// - アプリが書く索引の状態ファイル（データルートの `search-index.json`）が無い・作り直し中・
///   シグネチャ（`CoreMLEmbedder.Configuration.indexSignature`）がこちらの設定と食い違う → 標準エラーに警告
func makeEmbedderProvider(paths: CCPaths = .resolve()) -> EmbedderProvider {
    let box = LazyQueryEmbedder(paths: paths)
    return { await box.embedder() }
}

/// アプリ（`app/ContextCapture/App/Live/SearchIndex.swift` の `SearchIndexState`）が書く `search-index.json` の読み手。
/// **形式を変えるときはアプリ側と合わせる。**
struct SearchIndexStateFile: Decodable, Equatable {
    var indexSignature: String
    var imageTokens: Int
    var dimension: Int
    var status: String

    static let fileName = "search-index.json"

    enum CodingKeys: String, CodingKey {
        case indexSignature = "index_signature"
        case imageTokens = "image_tokens"
        case dimension
        case status
    }

    static func read(dataRoot: URL) -> SearchIndexStateFile? {
        guard let data = try? Data(contentsOf: dataRoot.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(SearchIndexStateFile.self, from: data)
    }
}

/// 検索のたびに索引の状態を読み直し（アプリが作り直しを終えれば次の検索からベクトルを使う）、合っていれば埋め込みを返す。
actor LazyQueryEmbedder {
    let paths: CCPaths
    private var cached: CoreMLEmbedder?
    /// 同じ理由の警告を検索のたびに出さない。
    private var lastWarning: String?

    init(paths: CCPaths) {
        self.paths = paths
    }

    func embedder() -> (any Embedder)? {
        let modelDirectory = paths.modelDirectory(.embedding)
        let required = ["EmbeddingGemma2Text.mlmodelc", "embeddings.bf16", "tokenizer.json"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path) }) else {
            warn("埋め込みモデルが無いので部分一致で検索する: \(modelDirectory.path)")
            return nil
        }
        guard let state = SearchIndexStateFile.read(dataRoot: paths.dataRoot) else {
            warn("索引の状態ファイル（\(SearchIndexStateFile.fileName)）が無いので部分一致で検索する。アプリで検索の準備が終わるのを待ってください")
            return nil
        }
        guard state.status == "ready" else {
            warn("アプリが検索の索引を作り直している（\(state.status)）ので部分一致で検索する")
            return nil
        }
        let configuration = CoreMLEmbedder.Configuration(
            modelDirectory: modelDirectory,
            imageTokens: ImageTokenBudget(rawValue: state.imageTokens) ?? .tokens280,
            textComputeUnits: .cpuAndGPU,
            visionComputeUnits: .cpuAndGPU,
            dimension: state.dimension
        )
        guard configuration.indexSignature == state.indexSignature else {
            warn("索引のシグネチャが食い違うのでベクトル検索を使わない（アプリ: \(state.indexSignature)、cc-mcp: \(configuration.indexSignature)）")
            return nil
        }
        if let cached, cached.configuration == configuration { return cached }
        let e = CoreMLEmbedder(configuration: configuration)
        cached = e
        lastWarning = nil
        MCPLog.write("埋め込み検索を使う（\(configuration.indexSignature)、CPU/GPU。初回の検索でテキスト塔を読み込む）")
        return e
    }

    private func warn(_ message: String) {
        cached = nil
        guard message != lastWarning else { return }
        lastWarning = message
        MCPLog.write(message)
    }
}
