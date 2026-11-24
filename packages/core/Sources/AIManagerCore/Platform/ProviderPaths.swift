import Foundation

public enum ProviderOS: String, Sendable {
    case macOS, Linux, Windows

    static let current: Self = {
        #if os(Windows)
        return .Windows
        #elseif os(Linux)
        return .Linux
        #else
        return .macOS
        #endif
    }()

    var agentName: String { self == .macOS ? "darwin" : rawValue.lowercased() }
}

struct ProviderPaths {
    @TaskLocal static var managerPaths: ManagerPaths?

    var home: URL
    var env: [String: String]
    var os: ProviderOS = .current

    static var current: Self {
        Self(home: (managerPaths ?? ManagerPaths.environment()).userHome, env: ProcessInfo.processInfo.environment)
    }

    func allowsRead(_ url: URL) -> Bool {
        (Self.managerPaths?.isolationRoot ?? override("AI_MANAGER_ROOT"))
            .map { CoreSupport.isContained(url, by: $0) } ?? true
    }

    func value(_ key: String) -> String? {
        let value = os == .Windows ? env.first { $0.key.uppercased() == key.uppercased() }?.value : env[key]
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    func override(_ key: String) -> URL? {
        guard let path = value(key) else { return nil }
        if path == "~" { return home }
        if path.hasPrefix("~/") || (os == .Windows && path.hasPrefix("~\\")) {
            return home.appending(path: String(path.dropFirst(2)))
        }
        return fileURL(path, directory: true)
    }

    func xdg(_ key: String, fallback: String) -> URL {
        if let path = value(key), absolute(path) {
            return fileURL(path, directory: true)
        }
        return home.appending(path: fallback, directoryHint: .isDirectory)
    }

    private func absolute(_ path: String) -> Bool {
        path.hasPrefix("/") || (os == .Windows && (path.hasPrefix("\\")
            || path.range(of: #"^[A-Za-z]:[/\\]"#, options: .regularExpression) != nil))
    }

    private func fileURL(_ path: String, directory: Bool) -> URL {
        guard os == .Windows, ProviderOS.current != .Windows else {
            return URL(fileURLWithPath: path, isDirectory: directory)
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let drive = normalized.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil
        return URL(fileURLWithPath: drive ? "/" + normalized : normalized, isDirectory: directory)
    }

    var roaming: URL { override("APPDATA") ?? home.appending(path: "AppData/Roaming") }
    var local: URL { override("LOCALAPPDATA") ?? home.appending(path: "AppData/Local") }
    var windowsNPMPrefix: URL { override("NPM_CONFIG_PREFIX") ?? roaming.appending(path: "npm") }

    func openCodeDatabase(in directory: URL) -> URL? {
        guard let path = value("OPENCODE_DB") else { return directory.appending(path: "opencode.db") }
        if path == ":memory:" { return nil }
        if absolute(path) { return fileURL(path, directory: false) }
        return directory.appending(path: path)
    }

    func appConfig(_ name: String) -> URL {
        let base: URL
        switch os {
        case .macOS: base = home.appending(path: "Library/Application Support")
        case .Linux: base = xdg("XDG_CONFIG_HOME", fallback: ".config")
        case .Windows: base = roaming
        }
        return base.appending(path: name)
    }

    func ideLogs(_ name: String) -> URL {
        let base: URL
        switch os {
        case .macOS: base = home.appending(path: "Library/Logs")
        case .Linux: base = xdg("XDG_CACHE_HOME", fallback: ".cache")
        case .Windows: base = local
        }
        return base.appending(path: name)
    }

    func root(_ root: ProviderFileRoot) -> URL {
        switch root {
        case .cursor: return appConfig("Cursor")
        case .windsurf: return appConfig("Windsurf")
        case .kiro:
            if os == .macOS { return appConfig("kiro-cli") }
            let base = os == .Windows ? local : xdg("XDG_DATA_HOME", fallback: ".local/share")
            return base.appending(path: "kiro-cli")
        case .kilo: return xdg("XDG_DATA_HOME", fallback: ".local/share").appending(path: "kilo")
        case .openCode:
            return override("OPENCODE_DATA_DIR") ?? xdg("XDG_DATA_HOME", fallback: ".local/share").appending(path: "opencode")
        case .gcloud:
            return override("CLOUDSDK_CONFIG") ?? (os == .Windows ? roaming : home.appending(path: ".config")).appending(path: "gcloud")
        case .gemini: return (override("GEMINI_CLI_HOME") ?? home).appending(path: ".gemini")
        case .kimi: return override("KIMI_CODE_HOME") ?? home.appending(path: ".kimi-code")
        case .devin:
            // docs.devin.ai on-disk formats: %APPDATA%\devin on Windows, XDG elsewhere.
            return (os == .Windows ? roaming : xdg("XDG_DATA_HOME", fallback: ".local/share")).appending(path: "devin")
        }
    }

    func stagedEnvironment() -> [String: String] {
        var selectors = [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appending(path: ".config").path,
            "XDG_DATA_HOME": home.appending(path: ".local/share").path,
            "XDG_CACHE_HOME": home.appending(path: ".cache").path,
            "XDG_STATE_HOME": home.appending(path: ".local/state").path,
        ]
        if os == .Windows {
            selectors["USERPROFILE"] = home.path
            selectors["APPDATA"] = home.appending(path: "AppData/Roaming").path
            selectors["LOCALAPPDATA"] = home.appending(path: "AppData/Local").path
            return env.filter { selectors[$0.key.uppercased()] == nil }.merging(selectors) { _, staged in staged }
        }
        return env.merging(selectors) { _, staged in staged }
    }

    mutating func set(_ key: String, to value: String) {
        if os == .Windows { env = env.filter { $0.key.uppercased() != key.uppercased() } }
        env[key] = value
    }
}
