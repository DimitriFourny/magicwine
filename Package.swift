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
        .target(name: "MagicWineCore", resources: [
            .copy("Resources/dxvk-macos-1.10.3-magicwine.2.tar.gz"),
            .copy("Resources/LICENSE-DXVK-DEPENDENCIES.txt"),
            .copy("Resources/dxmt-v0.80-builtin.tar.gz"),
            .copy("Resources/LICENSE-DXMT.txt"),
            .copy("Resources/winemac-wine11.0-dxmt.1.so.deflate"),
            .copy("Resources/winemac-wine11.0-dxmt.1-source.tar.gz"),
            .copy("Resources/winemac-wine11.0-dxmt.1-provenance.json"),
            .copy("Resources/LICENSE-WINE-DXMT.txt"),
            .copy("Resources/wow64cpu-wine11.0-magicwine.1.dll"),
            .copy("Resources/wow64cpu-wine11.0-magicwine.1-source.tar.gz"),
            .copy("Resources/LICENSE-WINE-WOW64CPU.txt")
        ]),
        .executableTarget(name: "MagicWine", dependencies: ["MagicWineCore"], resources: [.process("Assets")]),
        .executableTarget(name: "MagicWineCLI", dependencies: ["MagicWineCore"]),
        .testTarget(name: "MagicWineCoreTests", dependencies: ["MagicWineCore"])
    ]
)
