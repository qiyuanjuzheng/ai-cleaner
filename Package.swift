// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AICleaner",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AICleanerCore",
            targets: ["AICleanerCore"]
        ),
        .executable(
            name: "AICleanerApp",
            targets: ["AICleanerApp"]
        )
    ],
    targets: [
        .target(
            name: "AICleanerCore",
            path: "Sources/AICleanerCore"
        ),
        .executableTarget(
            name: "AICleanerApp",
            dependencies: ["AICleanerCore"],
            path: "Sources/AICleanerApp"
        ),
        .testTarget(
            name: "AICleanerCoreTests",
            dependencies: ["AICleanerCore"],
            path: "Tests/AICleanerCoreTests"
        ),
        .testTarget(
            name: "AICleanerAppTests",
            dependencies: ["AICleanerApp", "AICleanerCore"]
        )
    ]
)
