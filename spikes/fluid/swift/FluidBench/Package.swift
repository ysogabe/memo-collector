// swift-tools-version: 6.0
// FluidUse を SwiftPM のパス依存として取り込めるかを確かめ、EmbeddingGemma2Manager（Core ML）を計測するスパイク。
import PackageDescription

let package = Package(
    name: "FluidBench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../vendor/FluidUse")],
    targets: [
        .executableTarget(
            name: "eg2-bench", dependencies: [.product(name: "FluidUse", package: "FluidUse")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "eg2-image", dependencies: [.product(name: "FluidUse", package: "FluidUse")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ax-probe", dependencies: [.product(name: "FluidUse", package: "FluidUse")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
