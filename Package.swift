// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "whispr-lite", platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhisprLite", targets: ["WhisprLiteApp"]),
        .executable(name: "WhisprLiteCleanup", targets: ["WhisprLiteCleanup"])
    ],
    dependencies: [
        .package(url: "https://github.com/Bigsy/parakeet-ane-server.git", exact: "0.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "WhisprLiteCore", dependencies:
            [.product(name: "ParakeetCore", package: "parakeet-ane-server")]),
        .executableTarget(name: "WhisprLiteApp", dependencies: [
            "WhisprLiteCore", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "WhisprLiteCleanup", dependencies: ["WhisprLiteCore"]),
        .testTarget(name: "WhisprLiteCoreTests", dependencies:
            ["WhisprLiteCore", .product(name: "ParakeetCore", package: "parakeet-ane-server")]),
        .testTarget(name: "WhisprLiteAppTests", dependencies: ["WhisprLiteApp"])
    ]
)
