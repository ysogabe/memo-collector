// swift-tools-version: 6.0
import PackageDescription
let kit = "ContextCaptureKit"
let package = Package(
    name: "SearchEvaluation",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "cc-eval-search", targets: ["cc-eval-search"])],
    dependencies: [.package(path: "../../../Packages/ContextCaptureKit")],
    targets: [
        .target(name: "SearchEvaluation", dependencies: [.product(name: "CCCore", package: kit)]),
        .executableTarget(name: "cc-eval-search", dependencies: ["SearchEvaluation",
            .product(name: "CCCore", package: kit), .product(name: "CCStore", package: kit),
            .product(name: "CCEmbedding", package: kit), .product(name: "CCMCP", package: kit)]),
        .testTarget(name: "SearchEvaluationTests", dependencies: ["SearchEvaluation"]),
    ], swiftLanguageModes: [.v5]
)
