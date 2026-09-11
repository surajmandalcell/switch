// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AIManager",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AIManagerCore",
            targets: ["AIManagerCore"]
        ),
        .executable(
            name: "AIManager",
            targets: ["AIManagerGUI"]
        ),
        .executable(
            name: "ai-manager",
            targets: ["AIManagerTUI"]
        )
    ],
    targets: [
        .target(
            name: "AIManagerCore",
            dependencies: ["CSQLite"],
            path: "packages/core/Sources/AIManagerCore"
        ),
        .executableTarget(
            name: "AIManagerGUI",
            dependencies: ["AIManagerCore"],
            path: "packages/gui/Sources/AIManagerGUI"
        ),
        .executableTarget(
            name: "AIManagerTUI",
            dependencies: ["AIManagerCore"],
            path: "packages/tui/Sources/AIManagerTUI"
        ),
        .testTarget(
            name: "AIManagerCoreTests",
            dependencies: ["AIManagerCore"],
            path: "packages/core/Tests/AIManagerCoreTests"
        ),
        .systemLibrary(
            name: "CSQLite",
            path: "packages/core/Sources/CSQLite"
        )
    ]
)
