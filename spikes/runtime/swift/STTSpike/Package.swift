// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "STTSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "stt-swift",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        )
    ]
)
