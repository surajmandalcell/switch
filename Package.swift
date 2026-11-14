// swift-tools-version: 5.9

import PackageDescription

#if os(macOS)
let sqliteTarget = Target.systemLibrary(
    name: "CSQLite",
    path: "packages/core/Sources/CSQLite"
)
#elseif os(Windows)
// No system SQLite on Windows: a vendored amalgamation, published under the same module name.
let sqliteTarget = Target.target(
    name: "CSQLite",
    path: "packages/core/Sources/CSQLiteBundled",
    exclude: ["README.md"],
    sources: ["sqlite3.c"],
    publicHeadersPath: "include",
    cSettings: [
        .define("SQLITE_THREADSAFE", to: "1"),
        .define("SQLITE_OMIT_LOAD_EXTENSION"),
    ]
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
    .executable(
        name: "switch-core",
        targets: ["SwitchCoreCLI"]
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
                condition: .when(platforms: [.linux, .windows])
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
                condition: .when(platforms: [.linux, .windows])
            ),
        ],
        path: "packages/core/Tests/AIManagerCoreTests"
    ),
    .target(
        name: "SwitchAppModel",
        dependencies: ["AIManagerCore"],
        path: "packages/app-model/Sources/SwitchAppModel"
    ),
    .testTarget(
        name: "SwitchAppModelTests",
        dependencies: ["SwitchAppModel", "AIManagerCore"],
        path: "packages/app-model/Tests/SwitchAppModelTests"
    ),
    .target(
        name: "SwitchRPC",
        dependencies: ["SwitchAppModel", "AIManagerCore"],
        path: "packages/rpc/Sources/SwitchRPC"
    ),
    .executableTarget(
        name: "SwitchCoreCLI",
        dependencies: ["SwitchRPC", "AIManagerCore"],
        path: "packages/rpc/Sources/switch-core"
    ),
    .testTarget(
        name: "SwitchRPCTests",
        dependencies: ["SwitchRPC", "SwitchAppModel", "AIManagerCore"],
        path: "packages/rpc/Tests/SwitchRPCTests"
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
        path: "packages/mac-gui/Sources/AIManagerMacGUI"
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
