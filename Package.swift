// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "vec",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "VecKit", targets: ["VecKit"]),
        .executable(name: "vec", targets: ["vec"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
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
                "CSQLiteVec"
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
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
