// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vec",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "VecKit", targets: ["VecKit"]),
        .executable(name: "vec", targets: ["vec"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/jkrukowski/swift-embeddings", from: "0.0.26"),
        // swift-markdown publishes SemVer tags alongside its toolchain
        // release branches. 0.8.0 declares swift-tools-version 6.2, matching
        // our toolchain; Package.resolved pins the exact resolved version.
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.8.0")
    ],
    targets: [
        .systemLibrary(
            name: "CSQLiteVec",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite"])
            ]
        ),
        .target(
            name: "VecKit",
            dependencies: [
                "CSQLiteVec",
                .product(name: "Embeddings", package: "swift-embeddings"),
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .executableTarget(
            name: "vec",
            dependencies: [
                "VecKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "VecKitTests",
            dependencies: ["VecKit", "CSQLiteVec"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CLITests",
            dependencies: [
                "vec",
                "VecKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
