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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(
            name: "AICleanerCore",
            path: "Sources/AICleanerCore"
        ),
        .executableTarget(
            name: "AICleanerApp",
            dependencies: ["AICleanerCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AICleanerApp",
            resources: [.copy("Resources/ClientLogos")]
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
