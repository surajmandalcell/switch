import Foundation
import AIManagerCore

public enum SettingsError: Error, Equatable, LocalizedError {
    case unknownKey(String)
    case invalidValue(String)
    case tooLarge(String)
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let key): "Switch has no setting '\(key)'."
        case .invalidValue(let key): "That value does not fit the setting '\(key)'."
        case .tooLarge(let key): "The value of '\(key)' is larger than 64 KiB."
        case .readOnly: "The settings file comes from a newer Switch, so this build does not change it."
        }
    }
}

/// A typed key-value store with the Mac key names (architecture.md 3.1). `value` returns the stored value only
/// when it fits the registry; callers fall back to `SettingsRegistry` defaults.
public protocol SettingsStore: AnyObject, Sendable {
    func value(_ key: String) -> SettingValue?
    func set(_ key: String, _ value: SettingValue) throws
    func remove(_ key: String) throws
    func keys(prefix: String) -> [String]
    /// The key of every write made through this store. One consumer.
    var changes: AsyncStream<String> { get }
}

extension SettingsStore {
    /// The stored value, else the registry default.
    public func effective(_ key: String) -> SettingValue? {
        value(key) ?? SettingsRegistry.entry(key)?.defaultValue
    }
}

extension SettingsRegistry {
    /// Checks a value against the registry: known key, right type, listed choice, at most 64 KiB.
    public static func validate(_ key: String, _ value: SettingValue) throws {
        guard let entry = entry(key) else { throw SettingsError.unknownKey(key) }
        guard entry.type.accepts(value), entry.choices.map({ $0.contains(value) }) ?? true else {
            throw SettingsError.invalidValue(key)
        }
        guard JSONFileSettingsStore.size(of: value) <= maximumValueBytes else { throw SettingsError.tooLarge(key) }
    }
}

/// `settings.json` on Linux and Windows: `{"schemaVersion": 1, "values": {...}}`, written atomically, owner-only.
/// Unknown keys are kept. A corrupt file is renamed aside; a newer schema is read but never written.
public final class JSONFileSettingsStore: SettingsStore, @unchecked Sendable {
    public let url: URL
    /// Set once at load: a corrupt file was moved aside, or the file is from a newer build.
    public private(set) var notice: String?
    public let changes: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var values: [String: SettingValue] = [:]
    private var readOnly = false
    private var loggedWrongType: Set<String> = []
    private let log: (String) -> Void

    private struct Envelope: Codable {
        var schemaVersion: Int
        var values: [String: SettingValue]
    }

    public init(url: URL, log: @escaping (String) -> Void = { _ in }, now: Date = Date()) {
        self.url = url
        self.log = log
        (changes, continuation) = AsyncStream.makeStream(of: String.self)
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        guard let file = try? JSONDecoder().decode(Envelope.self, from: data) else {
            moveAside(now: now)
            return
        }
        values = file.values
        if file.schemaVersion > SettingsRegistry.schemaVersion {
            readOnly = true
            notice = "Settings come from a newer Switch (schema \(file.schemaVersion)). Changes are not saved."
        }
    }

    public func value(_ key: String) -> SettingValue? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key], let entry = SettingsRegistry.entry(key) else { return nil }
        guard entry.type.accepts(value), Self.size(of: value) <= SettingsRegistry.maximumValueBytes else {
            if loggedWrongType.insert(key).inserted { log("settings: '\(key)' has the wrong type or size; using the default") }
            return nil
        }
        return value
    }

    public func set(_ key: String, _ value: SettingValue) throws {
        try SettingsRegistry.validate(key, value)
        try write(key) { $0[key] = value }
    }

    public func remove(_ key: String) throws {
        try write(key) { $0[key] = nil }
    }

    public func keys(prefix: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func write(_ key: String, _ change: (inout [String: SettingValue]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !readOnly else { throw SettingsError.readOnly }
        var next = values
        change(&next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: SettingsRegistry.schemaVersion, values: next))
        // shortcut: POSIX owner-only modes, the folder is 0700 so the moment before chmod is private too; use
        // PrivateFiles (owner-only ACL on Windows) when Platform/ exposes it to this target (plan unit P1).
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        values = next
        continuation.yield(key)
    }

    /// Renames a corrupt file to `settings.corrupt-<unix seconds>.json`, keeping the newest 3, and starts empty.
    private func moveAside(now: Date) {
        let folder = url.deletingLastPathComponent()
        let aside = folder.appending(path: "settings.corrupt-\(Int(now.timeIntervalSince1970)).json")
        try? FileManager.default.removeItem(at: aside)
        guard (try? FileManager.default.moveItem(at: url, to: aside)) != nil else {
            readOnly = true
            notice = "Settings could not be read or moved aside, so defaults are used and changes are not saved."
            return
        }
        notice = "Settings could not be read, so defaults are used. The old file is \(aside.lastPathComponent)."
        let old = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("settings.corrupt-") && $0.hasSuffix(".json") }
            .sorted { Self.stamp($0) > Self.stamp($1) }
        for name in old.dropFirst(3) { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
    }

    private static func stamp(_ name: String) -> Int {
        Int(name.dropFirst("settings.corrupt-".count).dropLast(".json".count)) ?? 0
    }

    static func size(of value: SettingValue) -> Int {
        (try? JSONEncoder().encode(value).count) ?? Int.max
    }

    /// Where the helper keeps its settings: `<root>/settings.json` under `--root`, else
    /// `$XDG_CONFIG_HOME/switch` (default `~/.config/switch`) on Linux and `%APPDATA%\Switch` on Windows.
    // shortcut: resolved here until AppLocations (plan unit P11) owns every data location.
    public static func location(paths: ManagerPaths, environment: [String: String]) -> URL {
        if let root = paths.isolationRoot { return root.appending(path: "settings.json") }
        #if os(Windows)
        let base = environment["APPDATA"].map { URL(fileURLWithPath: $0) }
            ?? paths.userHome.appending(path: "AppData/Roaming")
        return base.appending(path: "Switch/settings.json")
        #else
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? paths.userHome.appending(path: ".config")
        return base.appending(path: "switch/settings.json")
        #endif
    }
}
