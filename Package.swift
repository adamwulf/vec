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
        // swift-markdown 0.6.0 declares swift-tools-version 5.7, so it keeps
        // this package's declared 6.0 minimum honest — 0.7.x / 0.8.x require
        // 6.2 and would silently raise it. Stay on the 0.6 minor line; its
        // source-location API (1-based UTF-8 byte columns) is identical to the
        // newer releases. Package.resolved pins the exact resolved revision.
        .package(url: "https://github.com/swiftlang/swift-markdown", .upToNextMinor(from: "0.6.0")),
        // Pin parser behavior for the versioned HTML reader. This release
        // declares Swift tools 6.0 and is shared by both selection options.
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.6")
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
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftSoup", package: "SwiftSoup")
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
