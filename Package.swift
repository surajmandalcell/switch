// swift-tools-version: 5.9

import PackageDescription

#if os(macOS)
let sqliteTarget = Target.systemLibrary(
    name: "CSQLite",
    path: "packages/core/Sources/CSQLite"
)
#else
let sqliteTarget = Target.systemLibrary(
    name: "CSQLite",
    path: "packages/core/Sources/CSQLite",
    pkgConfig: "sqlite3",
    providers: [.apt(["libsqlite3-dev"])]
)
#endif

var products: [Product] = [
    .library(
        name: "AIManagerCore",
        targets: ["AIManagerCore"]
    ),
    .executable(
        name: "ai-manager",
        targets: ["AIManagerTUI"]
    ),
]

var targets: [Target] = [
    .target(
        name: "AIManagerCore",
        dependencies: [
            "CSQLite",
            .product(
                name: "Crypto",
                package: "swift-crypto",
                condition: .when(platforms: [.linux])
            ),
        ],
        path: "packages/core/Sources/AIManagerCore"
    ),
    .executableTarget(
        name: "AIManagerTUI",
        dependencies: ["AIManagerCore"],
        path: "packages/tui/Sources/AIManagerTUI"
    ),
    .testTarget(
        name: "AIManagerCoreTests",
        dependencies: [
            "AIManagerCore",
            "CSQLite",
            .product(
                name: "Crypto",
                package: "swift-crypto",
                condition: .when(platforms: [.linux])
            ),
        ],
        path: "packages/core/Tests/AIManagerCoreTests"
    ),
    sqliteTarget,
]

#if os(macOS)
products.append(
    .executable(
        name: "AIManager",
        targets: ["AIManagerMacGUI"]
    )
)
targets.append(
    .executableTarget(
        name: "AIManagerMacGUI",
        dependencies: ["AIManagerCore"],
        path: "packages/mac-gui/Sources/AIManagerMacGUI",
        linkerSettings: [.linkedFramework("IOKit")]
    )
)
#endif

let package = Package(
    name: "AIManager",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            exact: "3.15.1"
        ),
    ],
    targets: targets
)
