// swift-tools-version: 6.0
// Context Capture のロジックをすべて収めるパッケージ。
// 契約: docs/plans/mvp-implementation.md §1。外部依存はここで全部宣言する（Wave 0 以降の担当は編集禁止。必要なら main へ報告）。
import PackageDescription

// MARK: - 外部依存の product（名前の打ち間違いを防ぐため 1 か所にまとめる）

let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")
let whisperKit: Target.Dependency = .product(name: "WhisperKit", package: "WhisperKit")
let mlx: Target.Dependency = .product(name: "MLX", package: "mlx-swift")
let mlxNN: Target.Dependency = .product(name: "MLXNN", package: "mlx-swift")
let mlxFast: Target.Dependency = .product(name: "MLXFast", package: "mlx-swift")
let mlxLMCommon: Target.Dependency = .product(name: "MLXLMCommon", package: "mlx-swift-lm")
let mlxLLM: Target.Dependency = .product(name: "MLXLLM", package: "mlx-swift-lm")
let mlxVLM: Target.Dependency = .product(name: "MLXVLM", package: "mlx-swift-lm")
let tokenizers: Target.Dependency = .product(name: "Tokenizers", package: "swift-transformers")
let hub: Target.Dependency = .product(name: "Hub", package: "swift-transformers")
let mcp: Target.Dependency = .product(name: "MCP", package: "swift-sdk")
let argumentParser: Target.Dependency = .product(name: "ArgumentParser", package: "swift-argument-parser")

let package = Package(
    name: "ContextCaptureKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CCCore", targets: ["CCCore"]),
        .library(name: "CCStore", targets: ["CCStore"]),
        .library(name: "CCCapture", targets: ["CCCapture"]),
        .library(name: "CCSTT", targets: ["CCSTT"]),
        .library(name: "CCIntent", targets: ["CCIntent"]),
        .library(name: "CCEmbedding", targets: ["CCEmbedding"]),
        .library(name: "CCGuard", targets: ["CCGuard"]),
        .library(name: "CCTriage", targets: ["CCTriage"]),
        .library(name: "CCModels", targets: ["CCModels"]),
        .library(name: "CCMCP", targets: ["CCMCP"]),
        .executable(name: "cc-models", targets: ["cc-models"]),
        .executable(name: "cc-mcp", targets: ["cc-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMinor(from: "7.11.1")),
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        // 型・プロトコル・パス解決。外部依存なし。
        .target(name: "CCCore"),
        // SQLite（GRDB）、添付ファイル、ベクトル検索、保持期間。
        .target(name: "CCStore", dependencies: ["CCCore", grdb]),
        // ホットキー、前面アプリ/ウインドウ（AX）、URL（AppleScript）、ScreenCaptureKit、録音。システムフレームワークのみ。
        .target(name: "CCCapture", dependencies: ["CCCore"]),
        // WhisperKit による日本語 STT。
        .target(name: "CCSTT", dependencies: ["CCCore", whisperKit]),
        // d1-3B on MLX Swift（プロンプト組み立て・readout・トークナイザ修正）。
        .target(name: "CCIntent", dependencies: ["CCCore", mlx, mlxNN, mlxFast, mlxLMCommon, mlxLLM, tokenizers]),
        // EmbeddingGemma 2 on MLX Swift（テキスト・画像・融合）。画像塔は MLXVLM/Gemma4 を流用する想定。
        .target(name: "CCEmbedding", dependencies: ["CCCore", mlx, mlxNN, mlxFast, mlxLMCommon, mlxVLM, tokenizers]),
        // Vision OCR + 秘密情報パターン、マスク画像生成。システムフレームワークのみ。
        .target(name: "CCGuard", dependencies: ["CCCore"]),
        // 非同期トリアージキュー、モデルのロード/解放。
        .target(name: "CCTriage", dependencies: ["CCCore", "CCStore", "CCIntent", "CCEmbedding", "CCGuard"]),
        // モデルの取得・変換・検証（HF ダウンロード、d1 抽出+8bit 量子化、チェックサム、WhisperKit モデル取得）。
        .target(name: "CCModels", dependencies: ["CCCore", hub, mlx, mlxNN, whisperKit]),
        // MCP ツール実装（ストアを読む・状態更新のみ）。
        .target(name: "CCMCP", dependencies: ["CCCore", "CCStore", "CCEmbedding", mcp]),
        // CLI: モデル準備（`cc-models prepare all`）。
        .executableTarget(name: "cc-models", dependencies: ["CCCore", "CCModels", argumentParser]),
        // CLI: stdio MCP サーバー（Claude Code / Hermes から起動される）。
        .executableTarget(name: "cc-mcp", dependencies: ["CCCore", "CCMCP", "CCStore", "CCEmbedding", mcp, argumentParser]),

        .testTarget(name: "CCCoreTests", dependencies: ["CCCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CCStoreTests", dependencies: ["CCStore", grdb]),
        .testTarget(name: "CCCaptureTests", dependencies: ["CCCapture"]),
        .testTarget(name: "CCSTTTests", dependencies: ["CCSTT"]),
        // Fixtures は #filePath から相対で読む（バンドルに入れない。生成スクリプト .py も含むため exclude）。
        .testTarget(name: "CCIntentTests", dependencies: ["CCIntent", mlx], exclude: ["Fixtures"]),
        .testTarget(name: "CCEmbeddingTests", dependencies: ["CCEmbedding"]),
        .testTarget(name: "CCGuardTests", dependencies: ["CCGuard"]),
        .testTarget(name: "CCTriageTests", dependencies: ["CCTriage"]),
        .testTarget(name: "CCModelsTests", dependencies: ["CCModels"]),
        .testTarget(name: "CCMCPTests", dependencies: ["CCMCP"]),
    ],
    swiftLanguageModes: [.v5]
)
