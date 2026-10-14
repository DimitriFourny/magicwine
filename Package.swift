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
            .copy("Resources/magicwine-xinput-v1-x86_64.dll"),
            .copy("Resources/magicwine-xinput-v1-i686.dll"),
            .copy("Resources/magicwine-xinput-v1-source.tar.gz"),
            .copy("Resources/LICENSE-MAGICWINE-GAMEPAD.txt"),
            .copy("Resources/dxvk-macos-1.10.3-magicwine.2.tar.gz"),
            .copy("Resources/LICENSE-DXVK-DEPENDENCIES.txt"),
            .copy("Resources/dxmt-v0.80-builtin.tar.gz"),
            .copy("Resources/dxmt-v0.80-remote.1.tar.gz"),
            .copy("Resources/dxmt-v0.80-remote.1-source.tar.gz"),
            .copy("Resources/dxmt-v0.80-remote.1-provenance.json"),
            .copy("Resources/LICENSE-DXMT.txt"),
            .copy("Resources/winemac-wine11.0-metal.6.so.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-x86_64.drv.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-i386.drv.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-x86_64.ntdll.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-i386.ntdll.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-ntdll.so.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-win32u.so.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-x86_64.user32.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-i386.user32.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-x86_64.wow64win.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-winhttp.so.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-x86_64.winhttp.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-i386.winhttp.deflate"),
            .copy("Resources/winemac-wine11.0-metal.6-source.tar.gz"),
            .copy("Resources/winemac-wine11.0-metal.6-provenance.json"),
            .copy("Resources/LICENSE-WINE-METAL.txt"),
            .copy("Resources/wow64cpu-wine11.0-magicwine.1.dll"),
            .copy("Resources/wow64cpu-wine11.0-magicwine.1-source.tar.gz"),
            .copy("Resources/LICENSE-WINE-WOW64CPU.txt")
        ]),
        .executableTarget(name: "MagicWine", dependencies: ["MagicWineCore"], resources: [.process("Assets")]),
        .executableTarget(name: "MagicWineCLI", dependencies: ["MagicWineCore"]),
        .testTarget(name: "MagicWineCoreTests", dependencies: ["MagicWineCore"])
    ]
)
