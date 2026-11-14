import Foundation
import AIManagerCore

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
                try settings.remove([key])
            }
        } catch SettingsError.readOnly {
            setNotice(SettingsError.readOnly.localizedDescription)
            throw SettingsError.readOnly
        }
        settingsChanged()
    }

    /// Reset settings (settings.md 2.8): removes every stored key of `group`, per-account keys included, in one write.
    /// The `settings` group is what the Mac Reset button removes; accounts and the `kept` keys stay.
    public func resetSettings(_ group: SettingKey.ResetGroup = .settings) throws {
        let keys = settings.storedKeys.filter { SettingsRegistry.entry($0)?.resetGroup == group }
        do {
            try settings.remove(keys)
        } catch SettingsError.readOnly {
            setNotice(SettingsError.readOnly.localizedDescription)
            throw SettingsError.readOnly
        }
        settingsChanged()
    }

    private func settingsChanged() {
        publish(.settings, Self.settingsValue(settings))
        // Privacy and hidden rows change the account rows; an unchanged row set publishes nothing.
        publishAccounts()
    }

    /// The error text the user sees: with privacy mode on, names in Droid and sign-in errors are made up, as the Mac
    /// `privacyDescription` does.
    public nonisolated func describe(_ error: Error) -> String {
        let privacy = PrivacySettings(settings)
        var text = error.localizedDescription
        if privacy.privacyMode {
            func label(_ value: String) -> String {
                value.contains("@") ? PrivacyText.display(value, privacy) : PrivacyText.fakeName(seed: value)
            }
            switch error {
            case DroidAccountError.confirmSignIn(let name):
                text = DroidAccountError.confirmSignIn(PrivacyText.fakeName(seed: name)).localizedDescription
            case DroidAccountError.duplicateIdentity(let name, let hint):
                text = DroidAccountError.duplicateIdentity(name: PrivacyText.fakeName(seed: name),
                                                           hint: PrivacyText.display(hint, privacy)).localizedDescription
            case AIManagerError.signInIdentityMismatch(let signedIn, let target):
                text = AIManagerError.signInIdentityMismatch(signedIn: label(signedIn), target: label(target))
                    .localizedDescription
            default: break
            }
        }
        return masked(text)
    }

    /// Beyond the Mac: any email in an error or notice is hidden when privacy or Hide email addresses is on.
    public nonisolated func masked(_ text: String) -> String {
        let privacy = PrivacySettings(settings)
        return privacy.privacyMode || privacy.hideEmails ? PrivacyText.display(text, privacy) : text
    }
}
