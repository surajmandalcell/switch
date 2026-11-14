import Foundation
import AIManagerCore

extension JSONFileSettingsStore {
    /// The helper's settings file. On Linux with a real home, the first open imports the old corelibs
    /// `UserDefaults` suite (architecture.md section 5).
    public static func open(paths: ManagerPaths, environment: [String: String]) -> JSONFileSettingsStore {
        let url = location(paths: paths, environment: environment)
        #if os(Linux)
        if paths.isolationRoot == nil, !FileManager.default.fileExists(atPath: url.path) {
            let suite = "com.mandalsuraj.ai-manager"
            _ = importLegacy(UserDefaults(suiteName: suite)?.persistentDomain(forName: suite) ?? [:], into: url)
        }
        #endif
        return JSONFileSettingsStore(url: url)
    }

    /// Copies the registry keys of `legacy` into a settings file that does not exist yet; unknown keys and values of
    /// the wrong type are skipped. Returns how many keys it copied.
    static func importLegacy(_ legacy: [String: Any], into url: URL) -> Int {
        guard !legacy.isEmpty, !FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let store = JSONFileSettingsStore(url: url)
        var count = 0
        for key in legacy.keys.sorted() {
            guard let entry = SettingsRegistry.entry(key), let value = settingValue(legacy[key]!, entry.type),
                  (try? store.set(key, value)) != nil else { continue }
            count += 1
        }
        return count
    }

    private static func settingValue(_ raw: Any, _ type: SettingType) -> SettingValue? {
        switch type {
        case .bool: (raw as? Bool).map(SettingValue.bool)
        case .int: (raw as? Int).map(SettingValue.int)
        case .double: (raw as? Double).map(SettingValue.double)
        case .string: (raw as? String).map(SettingValue.string)
        case .stringArray: (raw as? [String]).map { .array($0.map(SettingValue.string)) }
        // The Mac stores these as encoded JSON `Data`; the settings file keeps the object itself.
        case .object, .json: (raw as? Data).flatMap { try? JSONDecoder().decode(SettingValue.self, from: $0) }
        }
    }
}
