import AIManagerCore
import AppKit
import SwiftUI

@MainActor
enum AIManagerBrand {
  static let displayName = "Switch"
  static let traySize = NSSize(width: 22, height: 22)

  static func bundleDisplayName(in bundle: Bundle = .main) -> String {
    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? displayName
  }

  static func installApplicationIcon(dark: Bool? = nil, in bundle: Bundle = .main) {
    let usesDarkTreatment = dark ?? (
      NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    let treatment = usesDarkTreatment ? "AppIconDark" : "AppIconLight"
    if let image = image(named: treatment, extension: "png", bundle: bundle)
      ?? image(named: "AppIcon", extension: "png", bundle: bundle)
    {
      NSApp.applicationIconImage = image
    }
  }

  static func trayImage(in bundle: Bundle = .main) -> NSImage? {
    let image = NSImage(size: traySize)
    for name in ["TrayTemplate", "TrayTemplate@2x"] {
      guard let url = resourceURL(named: name, extension: "png", bundle: bundle),
        let data = try? Data(contentsOf: url),
        let representation = NSBitmapImageRep(data: data)
      else { continue }
      representation.size = traySize
      image.addRepresentation(representation)
    }
    guard !image.representations.isEmpty else { return nil }
    image.isTemplate = true
    return image
  }

  struct ProviderArtwork: Equatable {
    let providerID: ProviderID
    let resourceName: String
    let fileExtension: String
  }

  static let providerArtwork: [ProviderArtwork] = [
    .init(providerID: .codex, resourceName: "ProviderCodex", fileExtension: "png"),
    .init(providerID: .claudeCode, resourceName: "ProviderClaudeCode", fileExtension: "svg"),
    .init(providerID: .geminiCLI, resourceName: "ProviderGeminiCLI", fileExtension: "svg"),
    .init(
      providerID: .antigravityCLI,
      resourceName: "ProviderAntigravityCLI",
      fileExtension: "png"),
  ]

  static func providerImage(for providerID: ProviderID, in bundle: Bundle = .main) -> NSImage? {
    guard let artwork = providerArtwork.first(where: { $0.providerID == providerID }) else {
      return nil
    }
    return image(
      named: artwork.resourceName,
      extension: artwork.fileExtension,
      bundle: bundle)
  }

  static let providerGlyphNames: [String: String] = [
    "codex": "codex", "claude-code": "claudecode", "gemini-cli": "gemini",
    "antigravity-cli": "antigravity", "openai": "openai", "claude": "claude",
    "grok-build": "grok", "xai": "xai", "cursor": "cursor",
    "github-copilot": "githubcopilot", "copilot": "copilot", "cline": "cline",
    "windsurf": "windsurf", "opencode": "opencode", "amp": "amp", "goose": "goose",
    "deepseek": "deepseek", "qwen": "qwen", "mistral": "mistral",
    "ollama": "ollama", "perplexity": "perplexity",
  ]
  private static var glyphCache: [String: NSImage] = [:]

  static func providerGlyph(for providerID: ProviderID, in bundle: Bundle = .main) -> NSImage? {
    guard let name = providerGlyphNames[providerID.rawValue] else { return nil }
    let key = bundle.bundleURL.path + "/" + name
    if let image = glyphCache[key] { return image }
    guard let url = bundle.url(
      forResource: name, withExtension: "png", subdirectory: "Icons/ProviderGlyphs"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.isTemplate = true
    glyphCache[key] = image
    return image
  }

  static func statusImage(
    groups: [[MenuBarAccountSnapshot]], showsUsed: Bool = false, in bundle: Bundle = .main
  ) -> NSImage? {
    guard !groups.isEmpty else { return trayImage(in: bundle) }
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    let labels = groups.map { group in group.map { account in
      NSAttributedString(
        string: account.displayedPercentage(showsUsed: showsUsed).map { "\($0)%" } ?? "–",
        attributes: [.font: font, .foregroundColor: NSColor.black])
    } }
    let glyphs = groups.map {
      providerGlyph(for: $0[0].providerID, in: bundle)
        ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
    }
    let widths = labels.map { group in
      16 + group.reduce(0) { $0 + ceil($1.size().width) } + CGFloat(group.count - 1) * 5
    }
    let width = widths.reduce(0, +) + CGFloat(groups.count - 1) * 10
    let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
      var x: CGFloat = 0
      for index in labels.indices {
        glyphs[index]?.draw(in: NSRect(x: x, y: 5, width: 12, height: 12))
        x += 16
        for label in labels[index] {
          label.draw(at: NSPoint(x: x, y: floor((22 - label.size().height) / 2)))
          x += ceil(label.size().width) + 5
        }
        x += 5
      }
      return true
    }
    image.isTemplate = true
    return image
  }

  static func acceptanceFailures(in bundle: Bundle = .main) -> [String] {
    var failures: [String] = []
    for (name, fileExtension) in [
      ("AppIcon", "icns"), ("AppIcon", "png"),
      ("AppIconLight", "svg"), ("AppIconLight", "png"),
      ("AppIconDark", "svg"), ("AppIconDark", "png"),
      ("SwitchMarkPixelTrace", "svg"), ("SwitchMarkMenubar", "svg"),
      ("TrayTemplate", "png"), ("TrayTemplate@2x", "png"),
    ] where resourceURL(named: name, extension: fileExtension, bundle: bundle) == nil {
      failures.append("Brand asset \(name).\(fileExtension) is unavailable")
    }
    for artwork in providerArtwork {
      guard providerImage(for: artwork.providerID, in: bundle) != nil else {
        failures.append(
          "Provider asset \(artwork.resourceName).\(artwork.fileExtension) did not load")
        continue
      }
    }
    for id in providerGlyphNames.keys.sorted() {
      if providerGlyph(for: ProviderID(rawValue: id), in: bundle) == nil {
        failures.append("Provider menu glyph \(id) did not load")
      }
    }
    for name in ["AppIcon", "AppIconLight", "AppIconDark"] {
      guard let url = resourceURL(named: name, extension: "png", bundle: bundle),
        let data = try? Data(contentsOf: url),
        let representation = NSBitmapImageRep(data: data),
        representation.pixelsWide == 1024,
        representation.pixelsHigh == 1024
      else {
        failures.append("Dock brand asset \(name).png is not 1024 by 1024")
        continue
      }
    }
    guard let tray = trayImage(in: bundle) else {
      failures.append("Menu-bar brand mark did not load")
      return failures
    }
    if !tray.isTemplate { failures.append("Menu-bar brand mark is not a template image") }
    if tray.size != traySize { failures.append("Menu-bar brand mark is not 22 points") }
    let pixelWidths = Set(tray.representations.compactMap { ($0 as? NSBitmapImageRep)?.pixelsWide })
    if !pixelWidths.isSuperset(of: [22, 44]) {
      failures.append("Menu-bar brand mark is missing its native 1x or 2x representation")
    }
    return failures
  }

  private static func image(
    named name: String, extension fileExtension: String, bundle: Bundle
  ) -> NSImage? {
    guard let url = resourceURL(named: name, extension: fileExtension, bundle: bundle) else {
      return nil
    }
    return NSImage(contentsOf: url)
  }

  private static func resourceURL(
    named name: String, extension fileExtension: String, bundle: Bundle
  ) -> URL? {
    bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Icons")
      ?? bundle.url(forResource: name, withExtension: fileExtension)
  }
}

@MainActor
final class AIManagerStatusItemController: NSObject {
  var isPresent: Bool { statusItem.button?.image?.isTemplate == true }
  var usesPopover: Bool { statusItem.menu == nil && popover.behavior == .transient }
  var popoverContentSize: NSSize { popover.contentSize }
  var statusTitle: String {
    store.snapshot.statusAccounts.map {
      $0.displayedPercentage(showsUsed: showsUsed).map { "\($0)%" } ?? "–"
    }
      .joined(separator: " ")
  }
  var statusAccessibilityLabel: String { statusItem.button?.accessibilityLabel() ?? "" }

  private let statusItem: NSStatusItem
  private let popover = NSPopover()
  private let store: MenuBarPopoverStore
  private let bundle: Bundle
  private let defaults: UserDefaults
  private var showsUsed: Bool { UsagePercentagePreferences.showsUsed(defaults: defaults) }

  init(
    bundle: Bundle = .main,
    snapshot: MenuBarSnapshot = .empty,
    defaults: UserDefaults = .standard,
    actions: MenuBarPopoverActions
  ) {
    self.bundle = bundle
    self.defaults = defaults
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    store = MenuBarPopoverStore(snapshot: snapshot, actions: actions)
    super.init()

    let content = MenuBarPopover(store: store)
    popover.behavior = .transient
    popover.animates = false
    popover.contentViewController = NSHostingController(rootView: content)
    resizePopover()

    store.didSwitch = { [weak self] in self?.closePopover() }
    store.didRequestDismissal = { [weak self] in self?.closePopover() }
    configureButton()
    update(snapshot: snapshot)
  }

  deinit {
    let item = statusItem
    Task { @MainActor in NSStatusBar.system.removeStatusItem(item) }
  }

  func update(snapshot: MenuBarSnapshot) {
    store.update(snapshot: snapshot)
    updateStatusLabel(snapshot)
    if popover.isShown {
      resizePopover()
    }
  }

  func updateAppearance(_ appearance: NSAppearance?) {
    popover.appearance = appearance
    popover.contentViewController?.view.appearance = appearance
  }

  static func contentSize(
    accounts: [MenuBarAccountSnapshot],
    hasTokenStatistics: Bool = false,
    visibleScreenHeight: CGFloat
  ) -> NSSize {
    let listHeight: CGFloat
    if accounts.isEmpty {
      listHeight = MenuBarPopover.minimumHeight - MenuBarPopover.footerHeight
    } else {
      listHeight = MenuBarPopover.listInset * 2
        + accounts.map(MenuBarPopover.accountRowHeight).reduce(0, +)
        // NSTableView includes intercell spacing after its last row too.
        + CGFloat(accounts.count) * MenuBarPopover.cardSpacing
    }
    let idealHeight = MenuBarPopover.footerHeight + listHeight
      + (hasTokenStatistics ? MenuBarPopover.tokenStatisticsHeight : 0)
    let screenMaximum = max(MenuBarPopover.minimumHeight, floor(visibleScreenHeight * 0.80))
    let height = min(max(idealHeight, MenuBarPopover.minimumHeight), screenMaximum)
    return NSSize(width: MenuBarPopover.width, height: height)
  }

  private static let fallbackScreenHeight: CGFloat = 900
  private func resizePopover() {
    let screen = (popover.isShown ? popover.contentViewController?.view.window?.screen : nil)
      ?? statusItem.button?.window?.screen ?? NSScreen.main
    store.update(visibleScreenHeight: screen?.visibleFrame.height ?? Self.fallbackScreenHeight)
    popover.contentViewController?.view.layoutSubtreeIfNeeded()
    popover.contentSize = Self.contentSize(
      accounts: store.snapshot.accounts,
      hasTokenStatistics: !store.snapshot.sharedDailyActivity.isEmpty,
      visibleScreenHeight: store.visibleScreenHeight)
  }

  private func configureButton() {
    guard let button = statusItem.button else { return }
    button.image = AIManagerBrand.trayImage(in: bundle)
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(togglePopover)
    button.sendAction(on: [.leftMouseUp])
  }

  private func updateStatusLabel(_ snapshot: MenuBarSnapshot) {
    guard let button = statusItem.button else { return }
    let applicationName = AIManagerBrand.bundleDisplayName(in: bundle)
    let accounts = snapshot.statusAccounts
    button.title = ""
    button.imagePosition = .imageOnly
    button.image = AIManagerBrand.statusImage(
      groups: snapshot.statusAccountGroups, showsUsed: showsUsed, in: bundle)
    let description = accounts.map { account in
      let quota = account.usage.flatMap { usage in
        (usage.usedPercentage ?? usage.secondaryUsedPercentage).map {
          UsagePercentagePreferences.label(forUsed: $0, showsUsed: showsUsed)
        }
      } ?? "Limit not checked"
      return "\(account.providerID.displayName), \(account.identity), \(quota)"
    }.joined(separator: "\n")
    button.toolTip = description.isEmpty ? applicationName : description
    button.setAccessibilityLabel(
      description.isEmpty ? applicationName : applicationName + ", " + description)
  }

  @objc private func togglePopover() {
    if popover.isShown {
      closePopover()
      return
    }
    guard let button = statusItem.button else { return }
    resizePopover()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    resizePopover()
  }

  private func closePopover() {
    popover.performClose(nil)
  }
}
