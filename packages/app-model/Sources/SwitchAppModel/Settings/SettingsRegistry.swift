import Foundation
import AIManagerCore

/// A settings value as JSON: Bool, Int, Double, String, or a nested array or object.
public enum SettingValue: Codable, Equatable, Sendable {
    case bool(Bool), int(Int), double(Double), string(String), array([SettingValue]), object([String: SettingValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let int = try? value.decode(Int.self) { self = .int(int) }
        else if let double = try? value.decode(Double.self) { self = .double(double) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([SettingValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: SettingValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .bool(let bool): try value.encode(bool)
        case .int(let int): try value.encode(int)
        case .double(let double): try value.encode(double)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }
}

public enum SettingType: String, Codable, Sendable {
    case bool, int, double, string, stringArray
    /// A dictionary the Mac stores as a property-list dictionary.
    case object
    /// A value the Mac stores as encoded `Data`; here the nested JSON itself (object or array), never base64.
    case json

    func accepts(_ value: SettingValue) -> Bool {
        switch (self, value) {
        case (.bool, .bool), (.int, .int), (.double, .double), (.double, .int), (.string, .string), (.object, .object),
             (.json, .object), (.json, .array): true
        case (.stringArray, .array(let items)): items.allSatisfy { if case .string = $0 { true } else { false } }
        default: false
        }
    }
}

/// One settings key. `prefix` keys hold one value per account (`<key><account uuid>`).
public struct SettingKey: Sendable {
    public enum ResetGroup: String, Codable, Sendable {
        /// Removed by Reset settings (settings.md 2.8).
        case settings
        /// Kept by Reset settings: page state, window placement, menu-bar order, maintenance, update check.
        case kept
    }

    public let key: String
    public let type: SettingType
    /// Nil: absent means "not set" (the UI derives a value, such as now for `cleanupThrough`).
    public let defaultValue: SettingValue?
    public let resetGroup: ResetGroup
    public let isPrefix: Bool
    /// The only values `settings.set` accepts, when the Mac shows a fixed list.
    public let choices: [SettingValue]?

    /// A Bool whose Mac default is true: an absent key reads as on (settings.md 8.1).
    public var absentMeansOn: Bool { type == .bool && defaultValue == .bool(true) }
}

/// Every key the Mac app stores in its `UserDefaults` domain, with the type and default its source uses
/// (`@AppStorage` declarations and `UserDefaults` reads in packages/mac-gui). Left out: the core's
/// `switch.droid.keychainAllowed`, a Mac-only Keychain gate that the engine never uses (UserActionKeyProvider).
public enum SettingsRegistry {
    public static let schemaVersion = 1
    public static let maximumValueBytes = 64 * 1024

    public static let keys: [SettingKey] = {
        func key(_ name: String, _ type: SettingType, _ value: SettingValue?, _ group: SettingKey.ResetGroup = .settings,
                 prefix: Bool = false, choices: [SettingValue]? = nil) -> SettingKey {
            SettingKey(key: name, type: type, defaultValue: value, resetGroup: group, isPrefix: prefix, choices: choices)
        }
        let strings = { (values: [String]) in values.map(SettingValue.string) }
        return [
            // Reset by Reset settings.
            key("appearanceMode", .string, .string("system"), choices: strings(["system", "light", "dark"])),
            key("windowAppearance", .string, .string("system"), choices: strings(["system", "light", "dark"])),
            key("launchPlace", .string, .string("last"), choices: strings(["last", "overview"])),
            key("showEmailDomains", .bool, .bool(false)),
            key("hideEmailAddresses", .bool, .bool(false)),
            key("privacyMode", .bool, .bool(false)),
            key("usageTokenPeriod", .string, .string(CodexTokenPeriod.yearly.rawValue),
                choices: strings(CodexTokenPeriod.allCases.map(\.rawValue))),
            key("chat.messageFilterMask", .int, .int(ChatMessageFilter.all.rawValue)),
            key("minimizeToTray", .bool, .bool(false)),
            key("showAccountUsageInMenuBar", .bool, .bool(true)),
            key("menuBarTokenPeriod", .string, .string("sinceReset"),
                choices: strings(["sinceReset", "today", "yesterday", "weekly", "monthly", "yearly"])),
            key("menuBarOneAccountPerService", .bool, .bool(false)),
            key("showUsageAsUsed", .bool, .bool(false)),
            key("checkProviderStatus", .bool, .bool(true)),
            key("notifyAlmostOut", .bool, .bool(false)),
            key("notifyPaceAlerts", .bool, .bool(false)),
            key("notifyAvailableAgain", .bool, .bool(false)),
            key("notifySignInAgain", .bool, .bool(false)),
            key("resetTimesExact", .bool, .bool(false)),
            key("timeFormat", .string, .string("auto"), choices: strings(["auto", "12h", "24h"])),
            key("refreshWhenMenuOpens", .bool, .bool(false)),
            key("globalShortcut", .json, nil),
            key("autoSwitchEnabled", .bool, .bool(false)),
            key("autoSwitchThreshold", .int, .int(AutoSwitch.thresholds[0]), choices: AutoSwitch.thresholds.map(SettingValue.int)),
            key("autoSwitchRunningCLIs", .string, .string("restart"), choices: strings(["restart", "leave"])),
            key("autoSwitchResumeMessage", .string, .string(AutoSwitch.defaultResumeMessage)),
            key("showAccountUsageInMenuBar.account.", .bool, nil, prefix: true),
            key("hiddenUsageRows.", .string, .string(""), prefix: true),
            // Kept by Reset settings.
            key("lastPage", .string, nil, .kept),
            key("maintenanceTab", .string, .string("cleanup"), .kept),
            key("accountsFocus", .string, nil, .kept),
            key("scrollOffsets", .object, .object([:]), .kept),
            key("Switch.mainWindowPlacement.v1", .json, nil, .kept),
            key("overviewPeriod", .string, .string("week"), .kept, choices: strings(["week", "month", "year"])),
            key("overviewGrouping", .string, .string("account"), .kept, choices: strings(["account", "model", "project"])),
            key("menuBarServiceOrder", .stringArray, .array([]), .kept),
            key("menuBarHiddenServices", .stringArray, .array([]), .kept),
            key("menuBarHiddenAccounts", .stringArray, .array([]), .kept),
            key("menuBarExpandedAccount", .string, nil, .kept),
            key("chat.selectedID", .string, nil, .kept),
            key("chat.threadQuery", .string, .string(""), .kept),
            key("chat.messageQuery", .stringArray, nil, .kept),
            key("chat.anchor", .object, .object([:]), .kept),
            key("chat.threadsScroll", .double, nil, .kept),
            key("chat.blockStates", .object, .object([:]), .kept),
            key("maintenanceSource", .string, nil, .kept),
            key("backupDestination", .string, nil, .kept),
            key("backupShared", .json, nil, .kept),
            key("cleanupRange", .string, .string("Older than 30 days"), .kept),
            key("cleanupFrom", .double, nil, .kept),
            key("cleanupThrough", .double, nil, .kept),
            key("cleanupExpanded", .string, .string(""), .kept),
            key("cleanupProjects", .json, .array([]), .kept),
            key("cleanupTitle", .string, .string(""), .kept),
            key("updateCheckState", .json, nil, .kept),
        ]
    }()

    private static let byName = Dictionary(uniqueKeysWithValues: keys.filter { !$0.isPrefix }.map { ($0.key, $0) })

    /// The registry entry for a stored key name, prefix keys included. Nil for an unknown key.
    public static func entry(_ name: String) -> SettingKey? {
        if let entry = byName[name] { return entry }
        return keys.first { $0.isPrefix && name.hasPrefix($0.key) && name.count > $0.key.count }
    }
}
