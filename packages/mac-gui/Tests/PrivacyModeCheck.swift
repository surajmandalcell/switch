import AIManagerCore
import AppKit
import Foundation
import SwiftUI
import Vision

@MainActor enum PrivacyModeCheck {
  /// Synthetic accounts with known emails render with privacy on: no fixture email, local part, or Droid
  /// name shows in any visible string or accessibility label. Turning it off brings the real labels back
  /// in the same views, with no relaunch.
  static func renderedSurfaceFailures() -> [String] {
    var failures: [String] = []
    let defaults = UserDefaults.standard
    let key = EmailPrivacy.privacyModeKey
    let keys = [key, EmailPrivacy.key, EmailPrivacy.domainsKey]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (name, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: name) } else { defaults.removeObject(forKey: name) }
      }
    }
    defaults.set(false, forKey: key)
    defaults.set(false, forKey: EmailPrivacy.key)
    defaults.set(false, forKey: EmailPrivacy.domainsKey)

    let emails = [
      "ada@gmail.com", "grace.hopper@gmail.com", "linus.torvalds@outlook.com",
      "alan.turing@gmail.com", "katherine.johnson@gmail.com", "margaret.hamilton@gmail.com",
    ]
    let model = AccountViewModel(scenario: .demo)
    var accounts = model.status?.accounts ?? []
    for index in accounts.indices { accounts[index].identity.email = emails[index % emails.count] }
    model.status?.accounts = accounts
    guard let first = accounts.first, accounts.count >= 2 else { return ["Privacy mode: the demo has too few accounts"] }
    let used = Set(accounts.compactMap(\.identity.email))
    var secrets = Array(used) + used.compactMap { $0.split(separator: "@").first.map(String.init) }
    secrets += accounts.compactMap { $0.identity.providerID == .droid ? $0.identity.accountID : nil }

    func found(in strings: [String]) -> [String] {
      secrets.filter { secret in
        let escaped = NSRegularExpression.escapedPattern(for: secret)
        return strings.contains { $0.range(of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])", options: [.regularExpression, .caseInsensitive]) != nil }
      }
    }
    func texts(in element: Any, into strings: inout [String], depth: Int = 0) {
      guard depth < 40, let element = element as? NSAccessibilityProtocol else { return }
      strings += [element.accessibilityLabel(), element.accessibilityValue() as? String,
                  element.accessibilityHelp(), element.accessibilityTitle()].compactMap { $0 }
      for child in element.accessibilityChildren() ?? [] { texts(in: child, into: &strings, depth: depth + 1) }
    }
    func spin() { for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
    func mount<V: View>(_ view: V, _ size: NSSize) -> (NSHostingView<AnyView>, NSWindow) {
      let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .top)))
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      host.frame = NSRect(origin: .zero, size: size)
      host.layoutSubtreeIfNeeded()
      return (host, window)
    }
    func visible(_ host: NSView) -> [String] {
      spin()
      host.layoutSubtreeIfNeeded()
      var strings: [String] = []
      texts(in: host, into: &strings)
      // Offscreen, SwiftUI builds no accessibility tree (no assistive client), so the strings the eye sees
      // are read back from the drawn pixels at 2x. The accessibility walk still runs for any label it finds.
      let scale = 2
      guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * scale, pixelsHigh: Int(host.bounds.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0) else { return strings }
      bitmap.size = host.bounds.size
      host.cacheDisplay(in: host.bounds, to: bitmap)
      if let image = bitmap.cgImage {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        strings += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      }
      return strings
    }

    // The pages pass their Hide email addresses setting down, so a changed setting mounts the cards again.
    func mountTable(hide: Bool) -> (NSHostingView<AnyView>, NSWindow) {
      mount(AccountsTableCard(
        accounts: accounts, query: "", model: model, focusedID: first.id, now: Date(),
        hideEmails: hide, showsUsed: false, focus: { _ in }, delete: { _ in }), NSSize(width: 780, height: 700))
    }
    func mountCard(hide: Bool) -> (NSHostingView<AnyView>, NSWindow) {
      mount(FocusedAccountCard(
        account: first, model: model, now: Date(), hideEmails: hide, showsUsed: false, delete: {}),
        NSSize(width: 760, height: 400))
    }
    var table = mountTable(hide: false)
    var card = mountCard(hide: false)
    func snapshot() -> MenuBarSnapshot {
      MenuBarSnapshot(accounts: accounts.map {
        MenuBarAccountSnapshot(
          id: $0.id, identity: $0.identity.notificationLabel, detail: $0.identity.providerID.guiName,
          isVerified: true, isActive: false, providerID: $0.identity.providerID, identityIsFormatted: true,
          realName: $0.identity.realAccountLabel)
      })
    }
    let store = MenuBarPopoverStore(
      snapshot: snapshot(), actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }, openTool: { _ in }),
      visibleScreenHeight: 2_000)
    let popoverSize = AIManagerStatusItemController.contentSize(
      accounts: snapshot().accounts, visibleScreenHeight: 2_000, expandedID: nil)
    let popover = mount(MenuBarPopover(store: store), popoverSize)
    func legend() -> [String] {
      guard let history = model.usageHistory else { return [] }
      let data = OverviewDataset.make(
        summary: history.summary(period: .week, grouping: .account),
        year: history.summary(period: .year, grouping: .model), accounts: accounts,
        hideEmails: EmailPrivacy.isEnabled())
      return data.series.flatMap { [$0.label, $0.tipLabel] }
    }
    let surfaces: [(String, () -> [String])] = [
      ("Accounts table", { visible(table.0) }), ("focused account card", { visible(card.0) }),
      ("menu bar popover", { visible(popover.0) }), ("Overview legend", legend),
      ("menu bar tooltip", { snapshot().accounts.map(\.identity) }),
    ]

    // Off: every surface shows real labels (the harvest works, so an empty privacy result means something).
    for (name, strings) in surfaces where name != "menu bar tooltip" {
      let all = strings()
      if all.isEmpty || found(in: all).isEmpty { failures.append("Privacy mode off: \(name) shows no real account label") }
    }

    // On, live: the same views change without a relaunch.
    defaults.set(true, forKey: key)
    spin()
    store.update(snapshot: snapshot())
    for (name, strings) in surfaces {
      let all = strings()
      if all.isEmpty { failures.append("Privacy mode on: \(name) returned no strings to check") }
      let leaked = found(in: all)
      if !leaked.isEmpty { failures.append("Privacy mode on: \(name) shows \(leaked.sorted().joined(separator: ", "))") }
      if !all.contains(where: { $0.contains("@example.com") || $0.range(of: #"^[A-Z][a-z]+ [A-Z][a-z]+"#, options: .regularExpression) != nil }) {
        failures.append("Privacy mode on: \(name) shows no made-up name or email")
      }
    }
    if !snapshot().accounts.allSatisfy({ $0.providerID == .droid || used.contains($0.realName) }) {
      failures.append("Privacy mode: the popover Copy name value is not the real email with privacy on")
    }

    // Off again, live.
    defaults.set(false, forKey: key)
    spin()
    store.update(snapshot: snapshot())
    for (name, strings) in surfaces where name != "menu bar tooltip" {
      if found(in: strings()).isEmpty { failures.append("Privacy mode off again: \(name) did not bring the real labels back") }
    }

    // Hide email addresses on, Show full email addresses off: the mask drops the public ending too.
    defaults.set(true, forKey: EmailPrivacy.key)
    defaults.set(false, forKey: EmailPrivacy.domainsKey)
    spin()
    table.1.close()
    card.1.close()
    table = mountTable(hide: true)
    card = mountCard(hide: true)
    store.update(snapshot: snapshot())
    let ending = #"@[A-Za-z0-9\-]+\.[A-Za-z]{2,}"#
    for (name, strings) in surfaces where name != "menu bar tooltip" {
      let all = strings()
      if let shown = all.first(where: { $0.range(of: ending, options: .regularExpression) != nil }) {
        failures.append("Hide email addresses with domains off: \(name) shows an ending in \"\(shown)\"")
      }
      // A Droid account name is not an email: Hide email addresses leaves it alone.
      let mailboxes = found(in: all).filter { secret in used.contains(secret) || used.contains { $0.hasPrefix(secret + "@") } }
      if !mailboxes.isEmpty { failures.append("Hide email addresses: \(name) shows a full mailbox (\(mailboxes.joined(separator: ", ")))") }
    }
    if !legend().contains(where: { $0.contains("••••@gmail") }) {
      failures.append("Hide email addresses with domains off: the legend has no x••••@gmail label")
    }
    defaults.set(true, forKey: EmailPrivacy.domainsKey)
    if !legend().contains(where: { $0.contains("••••@gmail.com") }) {
      failures.append("Hide email addresses with domains on: the legend has no x••••@gmail.com label")
    }

    // A new Droid account name is typed input: empty with Privacy mode on, the usual default with it off.
    let adder = AccountViewModel(scenario: .demo)
    for (privacy, expectsEmpty) in [(true, true), (false, false)] {
      defaults.set(privacy, forKey: key)
      adder.resetAccountModal()
      if adder.droidAccountName.isEmpty != expectsEmpty {
        failures.append("Privacy mode \(privacy ? "on" : "off"): the new Droid account name is \"\(adder.droidAccountName)\"")
      }
    }
    for host in [table, card, popover] { host.1.close() }
    return failures
  }

  static func failures() -> [String] {
    var failures: [String] = renderedSurfaceFailures()
    let seed = "ada@gmail.com"
    let name = EmailPrivacy.fakeName(seed: seed)
    let email = EmailPrivacy.fakeEmail(seed: seed)
    if name != EmailPrivacy.fakeName(seed: seed) {
      failures.append("Privacy mode: the same seed changed its name")
    }
    if EmailPrivacy.fakeName(seed: "") != "Amy Lee" {
      failures.append("Privacy mode: the fixed FNV-1a seed changed its name")
    }
    if email != EmailPrivacy.fakeEmail(seed: seed) {
      failures.append("Privacy mode: the same seed changed its email")
    }
    if email != name.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com" {
      failures.append("Privacy mode: the email does not match the made-up name")
    }
    let names = Set((0..<20).map { EmailPrivacy.fakeName(seed: "person\($0)@example.test") })
    if names.count < 15 {
      failures.append("Privacy mode: 20 seeds produced fewer than 15 names")
    }
    let text = "Signed in as ada@gmail.com"
    let shown = EmailPrivacy.display(text, hide: false, showDomains: true, privacy: true)
    if shown.contains("ada") || !shown.contains("@example.com") {
      failures.append("Privacy mode: the real email is visible")
    }
    if shown != EmailPrivacy.display(text, hide: true, showDomains: false, privacy: true) {
      failures.append("Privacy mode: email settings override the made-up email")
    }
    if EmailPrivacy.display(text, hide: false, showDomains: true, privacy: false) != text {
      failures.append("Privacy mode: turning it off changes a full email")
    }
    // The existing domain setting shortens addresses when showDomains is false.
    if EmailPrivacy.display(text, hide: false, showDomains: false, privacy: false) != "Signed in as ada@gmail" {
      failures.append("Privacy mode: turning it off changed domain abbreviation")
    }
    let plain = "Codex Plus · 42 tokens"
    if EmailPrivacy.display(plain, hide: false, showDomains: false, privacy: false) != plain
      || EmailPrivacy.display(plain, hide: true, showDomains: false, privacy: true) != plain {
      failures.append("Privacy mode: provider, plan, or numbers changed")
    }
    if EmailPrivacy.display("ADA@GMAIL.COM", privacy: true) != email {
      failures.append("Privacy mode: email seeds are not lowercased")
    }
    // Hide email addresses x Show full email addresses; Privacy mode wins over both.
    for (hide, domains, expected) in [
      (true, false, "s••••@gmail"), (true, true, "s••••@gmail.com"),
      (false, false, "sara@gmail"), (false, true, "sara@gmail.com"),
    ] {
      if EmailPrivacy.display("sara@gmail.com", hide: hide, showDomains: domains, privacy: false) != expected {
        failures.append("Privacy mode: hide \(hide), full email \(domains) did not give \(expected)")
      }
      if EmailPrivacy.display("sara@gmail.com", hide: hide, showDomains: domains, privacy: true) != EmailPrivacy.fakeEmail(seed: "sara@gmail.com") {
        failures.append("Privacy mode: hide \(hide), full email \(domains) overrode the made-up email")
      }
    }
    let hint = "a***@gmail.com"
    if EmailPrivacy.display(hint, privacy: true) != EmailPrivacy.fakeEmail(seed: hint) {
      failures.append("Privacy mode: a masked login hint is visible")
    }
    let identity = AccountIdentity(providerID: .droid, email: seed, accountID: "Personal", authMode: .oauth)
    if identity.displayLabel(privacy: true) != "\(EmailPrivacy.fakeName(seed: "Personal")) · \(email)" {
      failures.append("Privacy mode: the Droid label exposes its name or email")
    }
    if identity.realAccountLabel != "Personal · ada@gmail.com" {
      failures.append("Privacy mode: the real account label changed")
    }
    if AccountIdentity(accountID: "Personal", authMode: .chatGPT).displayLabel(privacy: true)
      != EmailPrivacy.fakeName(seed: "Personal") {
      failures.append("Privacy mode: an account name is visible")
    }
    if AccountIdentity(providerID: .claudeCode, userID: "synthetic-user", authMode: .oauth).displayLabel(privacy: true)
      != EmailPrivacy.fakeName(seed: "synthetic-user") {
      failures.append("Privacy mode: a user ID tail is visible")
    }
    if AccountIdentity(authMode: .chatGPT).displayLabel(privacy: true) != "Unresolved account" {
      failures.append("Privacy mode: an unresolved account received a made-up name")
    }
    return failures
  }
}
