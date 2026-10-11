// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Published release. Local committed candidates can override it for validation.
let candidate = ProcessInfo.processInfo.environment["PARAKEET_CORE_PATH"]
let streamingEnabled = candidate == nil || ProcessInfo.processInfo.environment["PARAKEET_STREAMING"] == "1"
let package = Package(
    name: "whispr-lite", platforms: [.macOS(.v14)],
    products: [.executable(name: "WhisprLite", targets: ["WhisprLiteApp"]),
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
                    [.product(name: "ParakeetCore", package: "parakeet-ane-server")]),
        .executableTarget(name: "WhisprLiteApp", dependencies: ["WhisprLiteCore"]),
        .executableTarget(name: "WhisprLiteBench", dependencies:
                            ["WhisprLiteCore", .product(name: "ParakeetCore", package: "parakeet-ane-server"),
                             .product(name: "FluidAudio", package: "FluidAudio")],
                          swiftSettings: streamingEnabled ? [.define("PARAKEET_STREAMING")] : []),
        .testTarget(name: "WhisprLiteCoreTests", dependencies:
                    ["WhisprLiteCore", .product(name: "ParakeetCore", package: "parakeet-ane-server")])
    ]
)
