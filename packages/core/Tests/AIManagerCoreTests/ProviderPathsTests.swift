import Foundation
import XCTest
@testable import AIManagerCore

final class ProviderPathsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/synthetic/profile", isDirectory: true)

    func testLinuxConfigDataCacheAndOverrides() {
        let paths = ProviderPaths(home: home, env: [
            "XDG_CONFIG_HOME": "/synthetic/config",
            "XDG_DATA_HOME": "/synthetic/data",
            "XDG_CACHE_HOME": "/synthetic/cache",
            "KIMI_CODE_HOME": "/synthetic/kimi",
            "OPENCODE_DATA_DIR": "/synthetic/opencode",
            "OPENCODE_DB": "channels/preview.db",
        ], os: .Linux)
        XCTAssertEqual(paths.root(.cursor).path, "/synthetic/config/Cursor")
        XCTAssertEqual(paths.root(.windsurf).path, "/synthetic/config/Windsurf")
        XCTAssertEqual(paths.root(.kiro).path, "/synthetic/data/kiro-cli")
        XCTAssertEqual(paths.root(.kilo).path, "/synthetic/data/kilo")
        XCTAssertEqual(paths.root(.devin).path, "/synthetic/data/devin")
        XCTAssertEqual(paths.appConfig("JetBrains").path, "/synthetic/config/JetBrains")
        XCTAssertEqual(paths.ideLogs("JetBrains").path, "/synthetic/cache/JetBrains")
        XCTAssertEqual(paths.root(.kimi).path, "/synthetic/kimi")
        XCTAssertEqual(paths.root(.openCode).path, "/synthetic/opencode")
        XCTAssertEqual(paths.openCodeDatabase(in: paths.root(.openCode))?.path, "/synthetic/opencode/channels/preview.db")
        let defaults = ProviderPaths(home: home, env: [:], os: .Linux)
        XCTAssertEqual(defaults.root(.cursor).path, home.appending(path: ".config/Cursor").path)
        XCTAssertEqual(defaults.root(.openCode).path, home.appending(path: ".local/share/opencode").path)
    }

    func testWindowsRoamingLocalAndProviderOverrides() {
        let paths = ProviderPaths(home: home, env: [
            "AppData": "/synthetic/roaming", "LOCALAPPDATA": "/synthetic/local",
            "GEMINI_CLI_HOME": "/synthetic/gemini",
            "XDG_DATA_HOME": "relative",
        ], os: .Windows)
        XCTAssertEqual(paths.root(.cursor).path, "/synthetic/roaming/Cursor")
        XCTAssertEqual(paths.root(.windsurf).path, "/synthetic/roaming/Windsurf")
        XCTAssertEqual(paths.root(.gcloud).path, "/synthetic/roaming/gcloud")
        XCTAssertEqual(paths.root(.kiro).path, "/synthetic/local/kiro-cli")
        XCTAssertEqual(paths.ideLogs("JetBrains").path, "/synthetic/local/JetBrains")
        XCTAssertEqual(paths.root(.gemini).path, "/synthetic/gemini/.gemini")
        XCTAssertEqual(paths.root(.devin).path, "/synthetic/roaming/devin")
        XCTAssertEqual(paths.root(.kilo).path, home.appending(path: ".local/share/kilo").path)
        XCTAssertEqual(ProviderPaths(home: home, env: [:], os: .Windows).root(.cursor).path,
                       home.appending(path: "AppData/Roaming/Cursor").path)
    }

    func testMacDefaultsStayInTheirExistingFolders() {
        let paths = ProviderPaths(home: home, env: [:], os: .macOS)
        XCTAssertEqual(paths.root(.cursor).path, home.appending(path: "Library/Application Support/Cursor").path)
        XCTAssertEqual(paths.root(.windsurf).path, home.appending(path: "Library/Application Support/Windsurf").path)
        XCTAssertEqual(paths.root(.kiro).path, home.appending(path: "Library/Application Support/kiro-cli").path)
        XCTAssertEqual(paths.root(.gcloud).path, home.appending(path: ".config/gcloud").path)
        XCTAssertEqual(paths.ideLogs("JetBrains").path, home.appending(path: "Library/Logs/JetBrains").path)
    }

    /// Pins what master resolved on macOS with no overrides: every live file is `~/<file.path>`.
    func testMacLiveFilesMatchMasterForEveryProvider() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ProviderPathsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appending(path: "user")
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"),
                                 defaultHome: user.appending(path: ".codex"), sharedRoot: user.appending(path: ".codex"),
                                 orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
        let store = try ProviderAccountStore(paths: paths, environment: [:], os: .macOS)
        for spec in ProviderCatalog.all where !spec.files.isEmpty {
            XCTAssertEqual(store.credentialPaths(spec.id), spec.files.map { user.appending(path: $0.path).path }, spec.name)
        }
        let mac = ProviderPaths(home: user, env: [:], os: .macOS)
        XCTAssertEqual(mac.root(.kimi).appending(path: "device_id").path, user.appending(path: ".kimi-code/device_id").path)
        XCTAssertEqual(mac.root(.gemini).path, user.appending(path: ".gemini").path)
        XCTAssertEqual(mac.root(.openCode).path, user.appending(path: ".local/share/opencode").path)
        XCTAssertEqual(mac.openCodeDatabase(in: mac.root(.openCode))?.path, user.appending(path: ".local/share/opencode/opencode.db").path)
        XCTAssertEqual(mac.xdg("XDG_CACHE_HOME", fallback: ".cache").appending(path: "opencode").path, user.appending(path: ".cache/opencode").path)
        for vendor in ["JetBrains", "Google"] {
            XCTAssertEqual(mac.appConfig(vendor).path, user.appending(path: "Library/Application Support/\(vendor)").path)
            XCTAssertEqual(mac.ideLogs(vendor).path, user.appending(path: "Library/Logs/\(vendor)").path)
        }
        XCTAssertEqual(PiUsage.sessionDirectories(environment: [:], home: user).map(\.path),
                       [".pi/agent/sessions", ".omp/agent/sessions", ".local/share/omp/sessions"].map { user.appending(path: $0).path })
        let standard = ManagerPaths.environment([:], fileManager: SyntheticProfile(home: user))
        XCTAssertEqual(standard.defaultHome.path, user.appending(path: ".codex").path)
        XCTAssertEqual(standard.grokHome.path, user.appending(path: ".grok").path)
        XCTAssertEqual(standard.userHome.path, user.path)
    }

    func testMacUsageHelpersMatchMaster() throws {
        try XCTSkipUnless(ProviderOS.current == .macOS)
        let user = URL(fileURLWithPath: "/synthetic/user", isDirectory: true)
        XCTAssertEqual(WindsurfLocal.databaseURL(home: user, env: [:]).path,
                       user.appending(path: "Library/Application Support/Windsurf/User/globalStorage/state.vscdb").path)
        XCTAssertEqual(HTTP.userAgent, "Switch/3 (macOS)")
        XCTAssertTrue(AntigravityCLIUsage.userAgent.contains("os_type=darwin;"))
        XCTAssertTrue(AccountManager.shellIntegrationSupported)
    }

    func testWindowsDriveOverridesAreAbsolute() {
        let paths = ProviderPaths(home: home, env: ["XDG_DATA_HOME": #"C:\custom\data"#], os: .Windows)
        XCTAssertTrue(paths.root(.kilo).path.replacingOccurrences(of: "\\", with: "/").hasSuffix("C:/custom/data/kilo"))
    }

    func testDedicatedCLIOverridesKeepTheProviderProfileIndependent() {
        let profile = URL(fileURLWithPath: "/synthetic/profile", isDirectory: true)
        let codex = profile.appending(path: "custom/codex")
        let grok = profile.appending(path: "custom/grok")
        let fileManager = SyntheticProfile(home: profile)
        let environment = ["CODEX_HOME": codex.path, "GROK_HOME": grok.path]
        let paths = ManagerPaths.environment(environment, fileManager: fileManager)
        XCTAssertEqual(paths.defaultHome.path, codex.path)
        XCTAssertEqual(paths.sharedRoot.path, codex.path)
        XCTAssertEqual(paths.grokHome.path, grok.path)
        XCTAssertEqual(paths.userHome.path, profile.path)
        let isolated = ManagerPaths.environment(environment.merging(["AI_MANAGER_ROOT": "/synthetic/isolated"]) { _, new in new },
                                                fileManager: fileManager)
        XCTAssertEqual(isolated.defaultHome.lastPathComponent, "default-home")
        XCTAssertEqual(isolated.grokHome.lastPathComponent, "grok-home")
        XCTAssertEqual(isolated.userHome.lastPathComponent, "isolated")
    }

    private final class SyntheticProfile: FileManager, @unchecked Sendable {
        let home: URL
        init(home: URL) { self.home = home }
        override var homeDirectoryForCurrentUser: URL { home }
        override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [] }
    }

    func testProviderAvailabilityLeavesAPIKeyAndPastedSessionSourcesEnabled() {
        for os in [ProviderOS.Linux, .Windows] {
            let catalog = AccountManager.descriptors(for: ProviderCatalog.all, os: os)
            let unavailable = catalog.filter { $0.availability == .unavailable }
            XCTAssertEqual(Set(unavailable.map(\.id.rawValue)), ["antigravity-cli", "copilot"])
            XCTAssertTrue(unavailable.allSatisfy { $0.unavailableReason?.contains(os.rawValue) == true })
            XCTAssertEqual(catalog.first { $0.id.rawValue == "windsurf" }?.availability, .enabled)
            XCTAssertEqual(catalog.first { $0.id.rawValue == "kimi-api" }?.availability, .enabled)
        }
    }
}
