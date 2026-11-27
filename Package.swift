// swift-tools-version: 6.0
import PackageDescription

let products: [Product] = [
    .library(name: "AICleanerCore", targets: ["AICleanerCore"]),
    .executable(name: "aicleaner-core", targets: ["AICleanerSidecar"])
]
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.6.4")
]
let targets: [Target] = [
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
    .testTarget(name: "AICleanerCoreTests", dependencies: ["AICleanerCore", "CPlatformSupport", "CSQLite"]),
    .executableTarget(name: "AICleanerSidecar", dependencies: ["AICleanerCore", "CPlatformSupport"]),
    .testTarget(name: "AICleanerSidecarTests", dependencies: ["AICleanerSidecar", "AICleanerCore"])
]

let package = Package(
    name: "AICleaner",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
