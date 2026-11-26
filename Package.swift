// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "AICleanerCore", targets: ["AICleanerCore"])
]
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.4")
]
var targets: [Target] = [
    .target(
        name: "CPlatformSupport",
        linkerSettings: [
            .linkedLibrary("advapi32", .when(platforms: [.windows])),
            .linkedLibrary("ole32", .when(platforms: [.windows])),
            .linkedLibrary("shell32", .when(platforms: [.windows])),
            .linkedLibrary("uuid", .when(platforms: [.windows]))
        ]
    ),
    .target(name: "CSQLite", cSettings: [.define("SQLITE_OMIT_LOAD_EXTENSION")]),
    .target(
        name: "AICleanerCore",
        dependencies: ["CPlatformSupport", "CSQLite", .product(name: "Logging", package: "swift-log")]
    ),
    .testTarget(name: "AICleanerCoreTests", dependencies: ["AICleanerCore", "CPlatformSupport", "CSQLite"])
]

#if os(macOS)
products.append(.executable(name: "AICleanerApp", targets: ["AICleanerApp"]))
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"))
targets += [
    .executableTarget(
        name: "AICleanerApp",
        dependencies: ["AICleanerCore", .product(name: "Sparkle", package: "Sparkle")],
        resources: [.copy("Resources/ClientLogos")]
    ),
    .testTarget(name: "AICleanerAppTests", dependencies: ["AICleanerApp", "AICleanerCore"])
]
#endif

let package = Package(
    name: "AICleaner",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
