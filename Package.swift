// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Published release. Local committed candidates can override it for validation.
let candidate = ProcessInfo.processInfo.environment["PARAKEET_CORE_PATH"]
let streamingCandidate = candidate == nil || ProcessInfo.processInfo.environment["PARAKEET_STREAMING_CANDIDATE"] == "1"
let package = Package(
    name: "whispr-lite", platforms: [.macOS(.v14)],
    products: [.library(name: "WhisprLiteCore", targets: ["WhisprLiteCore"]),
               .executable(name: "WhisprLite", targets: ["WhisprLiteApp"]),
               .executable(name: "whispr-bench", targets: ["WhisprLiteBench"])],
    dependencies: (candidate.map { [.package(path: $0)] } ?? [
        .package(url: "https://github.com/Bigsy/parakeet-ane-server.git",
                 exact: "0.2.0")
    ]) + [
        // Bench-only VAD prototype; must match ParakeetCore's own exact FluidAudio pin.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7")
    ],
    targets: [
        .target(name: "WhisprLiteCore", dependencies:
                    [.product(name: "ParakeetCore", package: "parakeet-ane-server")],
                swiftSettings: streamingCandidate ? [.define("PARAKEET_STREAMING_CANDIDATE")] : []),
        .executableTarget(name: "WhisprLiteApp", dependencies: ["WhisprLiteCore"]),
        .executableTarget(name: "WhisprLiteBench", dependencies:
                            ["WhisprLiteCore", .product(name: "FluidAudio", package: "FluidAudio")],
                          swiftSettings: streamingCandidate ? [.define("PARAKEET_STREAMING_CANDIDATE")] : []),
        .testTarget(name: "WhisprLiteCoreTests", dependencies:
                    ["WhisprLiteCore", .product(name: "ParakeetCore", package: "parakeet-ane-server")])
    ]
)
