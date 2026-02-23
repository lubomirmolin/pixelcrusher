// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixelCrusher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PixelCrusherMacCore",
            targets: ["PixelCrusherMacCore"]
        ),
        .executable(
            name: "PixelCrusherMac",
            targets: ["PixelCrusherMac"]
        )
    ],
    targets: [
        .target(
            name: "PixelCrusherMacCore",
            path: "Sources/PixelCrusherMacCore"
        ),
        .executableTarget(
            name: "PixelCrusherMac",
            dependencies: ["PixelCrusherMacCore"],
            path: "Sources/PixelCrusherMac"
        ),
        .testTarget(
            name: "PixelCrusherMacCoreTests",
            dependencies: ["PixelCrusherMacCore"],
            path: "Tests/PixelCrusherMacCoreTests"
        )
    ]
)
