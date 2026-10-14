// swift-tools-version: 6.0
import Foundation
import PackageDescription
let kit = "ContextCaptureKit"
// Quality CI omits MLX/CoreML executable targets; it still runs the actual CCStore.
let contractOnly = ProcessInfo.processInfo.environment["CC_SEARCH_CONTRACT_ONLY"] == "1"
var products: [Product] = [.executable(name: "cc-search-contract", targets: ["cc-search-contract"])]
var targets: [Target] = [
    .target(name: "SearchEvaluation", dependencies: [.product(name: "CCCore", package: kit)]),
    .target(name: "SearchPoC", dependencies: ["SearchEvaluation", .product(name: "CCCore", package: kit), .product(name: "GRDB", package: "GRDB.swift")]),
    .target(name: "SearchContracts", dependencies: ["SearchEvaluation", "SearchPoC", .product(name: "CCCore", package: kit), .product(name: "CCStore", package: kit)]),
    .executableTarget(name: "cc-search-contract", dependencies: ["SearchContracts"]),
    .testTarget(name: "SearchEvaluationTests", dependencies: ["SearchEvaluation"]),
    .testTarget(name: "SearchPoCTests", dependencies: ["SearchPoC", "SearchEvaluation", .product(name: "CCCore", package: kit)]),
    .testTarget(name: "SearchContractTests", dependencies: ["SearchContracts", "SearchEvaluation", .product(name: "CCCore", package: kit), .product(name: "CCStore", package: kit)]),
]
if !contractOnly {
    products += [.executable(name: "cc-eval-search", targets: ["cc-eval-search"]), .executable(name: "cc-query-worker", targets: ["cc-query-worker"])]
    targets += [
        .executableTarget(name: "cc-eval-search", dependencies: ["SearchEvaluation", "SearchPoC", .product(name: "CCCore", package: kit), .product(name: "CCStore", package: kit), .product(name: "CCEmbedding", package: kit), .product(name: "CCMCP", package: kit)]),
        .executableTarget(name: "cc-query-worker", dependencies: [.product(name: "CCCore", package: kit), .product(name: "CCEmbedding", package: kit)]),
    ]
}
let package = Package(name: "SearchEvaluation", platforms: [.macOS(.v15)], products: products,
    dependencies: [.package(path: "../../../Packages/ContextCaptureKit"), .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1")],
    targets: targets, swiftLanguageModes: [.v5])
