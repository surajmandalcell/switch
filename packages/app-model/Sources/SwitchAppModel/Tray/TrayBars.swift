import Foundation
import AIManagerCore

// shortcut: copy of MenuBarUsagePreferences.swift.MenuBarBarChoices; delete when the Mac app adopts SwitchAppModel
struct TrayBarChoices: Equatable, Sendable {
    static let key = "menuBarBars"
    let glance: Set<String>
    let expanded: Set<String>

    init?(glance: [String], expanded: [String]) {
        let all = glance + expanded
        guard !glance.isEmpty, all.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: { $0.value < 32 }) }),
              Set(glance).count == glance.count, Set(expanded).count == expanded.count else { return nil }
        self.glance = Set(glance)
        self.expanded = Set(expanded).union(glance)
    }

    init?(_ value: SettingValue?) {
        guard case .object(let columns) = value, columns.count == 2,
              case .array(let glance) = columns["glance"], case .array(let expanded) = columns["expanded"] else { return nil }
        func ids(_ values: [SettingValue]) -> [String] {
            values.compactMap { if case .string(let id) = $0 { id } else { nil } }
        }
        let glanceIDs = ids(glance), expandedIDs = ids(expanded)
        guard glanceIDs.count == glance.count, expandedIDs.count == expanded.count else { return nil }
        self.init(glance: glanceIDs, expanded: expandedIDs)
    }

    var value: SettingValue {
        .object(["glance": .array(glance.sorted().map(SettingValue.string)),
                 "expanded": .array(expanded.sorted().map(SettingValue.string))])
    }
}

public struct TrayBars: Encodable, Sendable {
    public struct Bar: Encodable, Sendable {
        public let id: String
        public let label: String
        public let glance: Bool
        public let expanded: Bool
        public let isDefaultGlance: Bool
        public let isDefaultExpanded: Bool
    }

    public let bars: [Bar]
    public let isCustom: Bool

    // shortcut: copy of MenuBarBarsDialog.swift.MenuBarBarsState.rows; delete when the Mac app adopts SwitchAppModel
    init(accounts: [TrayAccount], choices: TrayBarChoices?) {
        let firstTwo = Set(accounts.flatMap { account -> [String] in
            var plain = account
            plain.barChoices = nil
            return TrayPresentation.lines(for: plain).compactMap(\.key)
        })
        isCustom = choices != nil
        bars = TrayPresentation.barTitles(accounts).map { title in
            let defaultGlance = firstTwo.contains(title)
            return Bar(id: title, label: title, glance: choices?.glance.contains(title) ?? defaultGlance,
                       expanded: choices?.expanded.contains(title) ?? true,
                       isDefaultGlance: defaultGlance, isDefaultExpanded: true)
        }
    }
}

extension AppEngine {
    var storedTrayBars: [String: SettingValue] {
        if case .object(let stored) = settings.value(TrayBarChoices.key) { return stored }
        return [:]
    }

    public func trayBars(providerID: ProviderID) throws -> TrayBars {
        guard AccountManager.providerCatalog.contains(where: { $0.id == providerID })
                || status?.accounts.contains(where: { $0.identity.providerID == providerID }) == true else {
            throw AppEngineError.notFound("No provider has that ID.")
        }
        let accounts = trayAccounts().filter { $0.providerID == providerID }
        return TrayBars(accounts: accounts, choices: TrayBarChoices(storedTrayBars[providerID.rawValue]))
    }

    public func setTrayBars(providerID: ProviderID, glance: [String], expanded: [String]) throws -> TrayBars {
        _ = try trayBars(providerID: providerID)
        guard let choices = TrayBarChoices(glance: glance, expanded: expanded) else {
            throw SettingsError.invalidValue(TrayBarChoices.key)
        }
        var stored = storedTrayBars
        stored[providerID.rawValue] = choices.value
        try setSetting(TrayBarChoices.key, .object(stored))
        return try trayBars(providerID: providerID)
    }

    public func resetTrayBars(providerID: ProviderID) throws -> TrayBars {
        _ = try trayBars(providerID: providerID)
        var stored = storedTrayBars
        stored[providerID.rawValue] = nil
        try setSetting(TrayBarChoices.key, stored.isEmpty ? nil : .object(stored))
        return try trayBars(providerID: providerID)
    }
}
