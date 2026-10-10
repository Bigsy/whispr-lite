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
    dependencies: candidate.map { [.package(path: $0)] } ?? [
        .package(url: "https://github.com/Bigsy/parakeet-ane-server.git",
                 exact: "0.2.0")
    ],
    targets: [
        .target(name: "WhisprLiteCore", dependencies:
                    [.product(name: "ParakeetCore", package: "parakeet-ane-server")],
                swiftSettings: [.define("PARAKEET_CORE")] + (streamingCandidate ? [.define("PARAKEET_STREAMING_CANDIDATE")] : [])),
        .executableTarget(name: "WhisprLiteApp", dependencies: ["WhisprLiteCore"]),
        .executableTarget(name: "WhisprLiteBench", dependencies: ["WhisprLiteCore"],
                          swiftSettings: streamingCandidate ? [.define("PARAKEET_STREAMING_CANDIDATE")] : []),
        .testTarget(name: "WhisprLiteCoreTests", dependencies: ["WhisprLiteCore"])
    ]
)
