// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MagicWine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MagicWineCore", targets: ["MagicWineCore"]),
        .executable(name: "MagicWine", targets: ["MagicWine"]),
        .executable(name: "magicwine-cli", targets: ["MagicWineCLI"])
    ],
    targets: [
        .target(name: "MagicWineCore"),
        .executableTarget(name: "MagicWine", dependencies: ["MagicWineCore"]),
        .executableTarget(name: "MagicWineCLI", dependencies: ["MagicWineCore"]),
        .testTarget(name: "MagicWineCoreTests", dependencies: ["MagicWineCore"])
    ]
)
