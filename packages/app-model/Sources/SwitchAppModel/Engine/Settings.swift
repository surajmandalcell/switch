import Foundation

/// `settings` topic: the effective value of every key that has one (stored, else the registry default), plus every
/// stored per-account key.
public struct SettingsTopicValue: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var values: [String: SettingValue]
}

extension AppEngine {
    static func settingsValue(_ store: any SettingsStore) -> SettingsTopicValue {
        var values: [String: SettingValue] = [:]
        for entry in SettingsRegistry.keys {
            if entry.isPrefix {
                for key in store.keys(prefix: entry.key) { values[key] = store.value(key) }
            } else if let value = store.effective(entry.key) {
                values[entry.key] = value
            }
        }
        return SettingsTopicValue(schemaVersion: SettingsRegistry.schemaVersion, values: values)
    }

    /// The effective values of `keys`, or of every key. An unknown key throws `unknownKey`.
    public func settingsValues(_ keys: [String]?) throws -> SettingsTopicValue {
        var value = Self.settingsValue(settings)
        if let keys {
            for key in keys where SettingsRegistry.entry(key) == nil { throw SettingsError.unknownKey(key) }
            value.values = value.values.filter { keys.contains($0.key) }
        }
        return value
    }

    /// Stores one value after registry validation; nil removes it, so the default applies again.
    /// Settings are not an action: they do not wait for the action lane, as on the Mac.
    public func setSetting(_ key: String, _ value: SettingValue?) throws {
        do {
            if let value { try settings.set(key, value) } else {
                guard SettingsRegistry.entry(key) != nil else { throw SettingsError.unknownKey(key) }
                try settings.remove(key)
            }
        } catch SettingsError.readOnly {
            setNotice(SettingsError.readOnly.localizedDescription)
            throw SettingsError.readOnly
        }
        publish(.settings, Self.settingsValue(settings))
    }
}
