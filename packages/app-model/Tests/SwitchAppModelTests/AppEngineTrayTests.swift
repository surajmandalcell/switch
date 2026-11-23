import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel

/// The `tray` topic from the engine: it follows usage and the settings it reads, and masks every label.
extension AppEngineAccountsTests {
    func tray(_ engine: AppEngine) async -> TrayValue? { await engine.latest(.tray) as? TrayValue }

    func testTrayTopicFollowsUsageAndSettings() async throws {
        let (engine, id) = try await start(Script(), clock: ManualClock())
        var value = try await trayNow(engine)
        let trayRow = try XCTUnwrap(value.groups.first?.rows.first)
        XCTAssertEqual(trayRow.id, id.uuidString.lowercased())
        XCTAssertEqual(trayRow.lines.map(\.label), ["Session"])
        XCTAssertEqual(trayRow.lines.first?.percentText, "60%")
        XCTAssertEqual(trayRow.lines.first?.fill, 0.6)
        XCTAssertEqual(trayRow.lines.first?.isHigh, false)
        XCTAssertEqual(value.status.map(\.percentText), ["60%"])
        XCTAssertEqual(value.groups.first?.showsInTray, true)

        // Each setting the popover reads republishes the topic.
        try await engine.setSetting("showUsageAsUsed", .bool(true))
        value = try await trayNow(engine)
        XCTAssertEqual(value.groups.first?.rows.first?.lines.first?.percentText, "40%")
        XCTAssertEqual(value.status.map(\.percentText), ["40%"])
        try await engine.setSetting("menuBarHiddenAccounts", .array([.string(id.uuidString)]))
        value = try await trayNow(engine)
        XCTAssertEqual(value.status.count, 0)
        XCTAssertEqual(value.groups.first?.rows.first?.showsInTray, false)
        try await engine.setSetting("showAccountUsageInMenuBar.account.\(id.uuidString)", .bool(false))
        value = try await trayNow(engine)
        XCTAssertEqual(value.groups.count, 0, "an account with usage off leaves the popover, as on the Mac")
        try await engine.setSetting("showAccountUsageInMenuBar.account.\(id.uuidString)", nil)

        // The tray label is the accounts topic label, privacy rules included.
        try await engine.setSetting("privacyMode", .bool(true))
        let label = try await trayNow(engine).groups.first?.rows.first?.label
        let accountLabel = await row(engine)?.label
        XCTAssertEqual(label, accountLabel)
    }

    private func trayNow(_ engine: AppEngine) async throws -> TrayValue {
        let value = await tray(engine)
        return try XCTUnwrap(value)
    }

    func testTrayBarChoicesValidatePersistRepublishAndReset() async throws {
        let windows = ["Session", "Weekly", "Core Monthly"].map { UsageWindow(id: $0, title: $0, usedPercent: 40) }
        let (engine, _) = try await start(Script(windows: windows), clock: ManualClock())
        let defaults = try await engine.trayBars(providerID: provider)
        XCTAssertEqual(defaults.bars.filter(\.isDefaultGlance).map(\.id), ["Session", "Weekly"])
        XCTAssertTrue(defaults.bars.allSatisfy(\.isDefaultExpanded))
        XCTAssertFalse(defaults.isCustom)

        let changed = try await engine.setTrayBars(providerID: provider, glance: ["Core Monthly"], expanded: ["Weekly"])
        XCTAssertEqual(changed.bars.filter(\.glance).map(\.id), ["Core Monthly"])
        XCTAssertEqual(changed.bars.filter(\.expanded).map(\.id), ["Weekly", "Core Monthly"])
        XCTAssertTrue(changed.isCustom)
        let saved = try await engine.settingsValues(["menuBarBars"]).values["menuBarBars"]
        XCTAssertNotNil(saved)
        let row = try await trayRow(engine)
        XCTAssertEqual(row.lines.map(\.label), ["Core", "Monthly"])
        XCTAssertEqual(row.expandedLines.map(\.label), ["Weekly", "Core", "Monthly"])

        for bad in [[], ["unknown"], ["Weekly", "Weekly"]] {
            do {
                _ = try await engine.setTrayBars(providerID: provider, glance: bad, expanded: [])
                XCTFail("invalid glance selection accepted")
            } catch {
                XCTAssertEqual(error as? SettingsError, .invalidValue("menuBarBars"))
            }
        }
        let reset = try await engine.resetTrayBars(providerID: provider)
        XCTAssertFalse(reset.isCustom)
        XCTAssertEqual(reset.bars.filter(\.glance).map(\.id), ["Session", "Weekly"])
        let removed = try await engine.settingsValues(["menuBarBars"]).values["menuBarBars"]
        XCTAssertNil(removed)
        let restored = try await trayRow(engine)
        XCTAssertEqual(restored.lines.map(\.label), ["Session", "Weekly"])
        await engine.stop()
    }

    private func trayRow(_ engine: AppEngine) async throws -> TrayRowValue {
        let value = try await trayNow(engine)
        return try XCTUnwrap(value.groups.first?.rows.first)
    }

    func testTrayLabelsMaskEmails() {
        let codex = AccountIdentity(providerID: .codex, email: "ada.lovelace@example.com", authMode: .chatGPT)
        let droid = AccountIdentity(providerID: .droid, email: "grace@example.com", accountID: "Work", authMode: .chatGPT)
        let real = PrivacySettings(showDomains: true)
        XCTAssertEqual(AppEngine.trayLabel(codex, real), "ada.lovelace@example.com")
        XCTAssertEqual(AppEngine.trayLabel(AccountIdentity(providerID: .codex, authMode: .chatGPT), real),
                       "\(ProviderID.codex.displayName) account")
        for privacy in [PrivacySettings(hideEmails: true), PrivacySettings(privacyMode: true),
                        PrivacySettings(hideEmails: true, showDomains: true)] {
            for identity in [codex, droid] {
                let label = AppEngine.trayLabel(identity, privacy)
                XCTAssertFalse(label.contains("ada.lovelace") || label.contains("grace@"), label)
                XCTAssertEqual(label, identity.providerID == .codex && !privacy.privacyMode
                               ? PrivacyText.display(identity.email!, privacy) : PrivacyText.label(identity, privacy))
            }
        }
        // The tooltip and the accessibility label only repeat the masked label.
        let account = TrayAccount(identity: AppEngine.trayLabel(codex, PrivacySettings(privacyMode: true)),
                                  usage: TrayUsage(usedPercentage: 10))
        let tooltip = TrayPresentation.statusTooltip([account], shown: [account], hiddenServices: [], hiddenAccounts: [],
                                                     onePerService: false, showsUsed: false)
        XCTAssertFalse(tooltip.contains("ada.lovelace"), tooltip)
        XCTAssertFalse(TrayPresentation.accessibilityLabel(account, showsUsed: false, now: Date(), exact: false)
            .contains("ada.lovelace"))
    }
}
