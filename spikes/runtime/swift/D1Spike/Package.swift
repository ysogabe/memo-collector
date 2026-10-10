// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "D1Spike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
    ],
    targets: [
        .executableTarget(
            name: "d1-swift",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "embed-swift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
