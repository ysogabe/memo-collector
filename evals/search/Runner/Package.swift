// swift-tools-version: 6.0
import PackageDescription
let kit = "ContextCaptureKit"
let package = Package(
    name: "SearchEvaluation",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "cc-eval-search", targets: ["cc-eval-search"]), .executable(name: "cc-query-worker", targets: ["cc-query-worker"])],
    dependencies: [.package(path: "../../../Packages/ContextCaptureKit"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1")],
    targets: [
        .target(name: "SearchEvaluation", dependencies: [.product(name: "CCCore", package: kit)]),
        .target(name: "SearchPoC", dependencies: ["SearchEvaluation", .product(name: "CCCore", package: kit), .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "cc-eval-search", dependencies: ["SearchEvaluation", "SearchPoC",
            .product(name: "CCCore", package: kit), .product(name: "CCStore", package: kit),
            .product(name: "CCEmbedding", package: kit), .product(name: "CCMCP", package: kit)]),
        .executableTarget(name: "cc-query-worker", dependencies: [.product(name: "CCCore", package: kit), .product(name: "CCEmbedding", package: kit)]),
        .testTarget(name: "SearchEvaluationTests", dependencies: ["SearchEvaluation"]),
        .testTarget(name: "SearchPoCTests", dependencies: ["SearchPoC", "SearchEvaluation", .product(name: "CCCore", package: kit)]),
    ], swiftLanguageModes: [.v5]
)
