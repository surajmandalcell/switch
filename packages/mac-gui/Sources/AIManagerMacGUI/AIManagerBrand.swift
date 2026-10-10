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

  // MARK: Provider icons for every generic provider

  /// Provider id -> `ProviderIcon-<name>.svg` when the two differ. Other ids use their own name.
  static let providerIconAliases: [String: String] = [
    "gemini-cli": "gemini", "antigravity-cli": "antigravity", "grok-build": "grok",
    "claude-code": "claude", "github-copilot": "copilot",
    "kimi-api": "kimi", "moonshot": "kimi", "qwencloud-team": "qwencloud",
    "alibabatokenplan": "alibaba", "azureopenai": "openai",
  ]
  private static var providerIconCache: [String: NSImage] = [:]

  static func providerIconName(for providerID: ProviderID) -> String {
    providerIconAliases[providerID.rawValue] ?? providerID.rawValue
  }

  /// Monochrome template icon for any provider id. Existing glyphs win, then the packaged
  /// CodexBar SVG, then a monogram. Loaded once per id; callers never touch the disk on redraw.
  static func providerIcon(for providerID: ProviderID, in bundle: Bundle = .main) -> NSImage {
    let key = bundle.bundleURL.path + "|" + providerID.rawValue
    if let image = providerIconCache[key] { return image }
    let name = providerIconName(for: providerID)
    let image = providerGlyph(for: providerID, in: bundle)
      ?? providerGlyph(for: ProviderID(rawValue: name), in: bundle)
      ?? providerSVG(named: name, in: bundle)
      ?? monogram(for: providerID)
    providerIconCache[key] = image
    return image
  }

  /// True when the id has real artwork, so the monogram fallback is not in use.
  static func hasProviderArtwork(for providerID: ProviderID, in bundle: Bundle = .main) -> Bool {
    let name = providerIconName(for: providerID)
    return providerGlyphNames[providerID.rawValue] != nil || providerGlyphNames[name] != nil
      || providerSVGURL(named: name, in: bundle) != nil
  }

  private static func providerSVGURL(named name: String, in bundle: Bundle) -> URL? {
    bundle.url(
      forResource: "ProviderIcon-\(name)", withExtension: "svg",
      subdirectory: "Icons/ProviderIcons")
  }

  private static func providerSVG(named name: String, in bundle: Bundle) -> NSImage? {
    guard let url = providerSVGURL(named: name, in: bundle),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.isTemplate = true
    return image
  }

  /// First letter in a small rounded square, drawn as a template at the glyph size.
  static func monogram(for providerID: ProviderID) -> NSImage {
    let letter = String(
      (ProviderCatalog.spec(providerID)?.name ?? providerID.rawValue).first.map { Character($0.uppercased()) }
        ?? "?")
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
      let box = rect.insetBy(dx: 1, dy: 1)
      let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
      path.lineWidth = 1.2
      NSColor.black.setStroke()
      path.stroke()
      let text = NSAttributedString(
        string: letter,
        attributes: [
          .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
          .foregroundColor: NSColor.black,
        ])
      let size = text.size()
      text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
      return true
    }
    image.isTemplate = true
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
    let glyphs = groups.map { providerIcon(for: $0[0].providerID, in: bundle) }
    let widths = labels.map { group in
      16 + group.reduce(0) { $0 + ceil($1.size().width) } + CGFloat(group.count - 1) * 5
    }
    let width = widths.reduce(0, +) + CGFloat(groups.count - 1) * 10
    let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
      var x: CGFloat = 0
      for index in labels.indices {
        glyphs[index].draw(in: NSRect(x: x, y: 5, width: 12, height: 12))
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
      ("AppIconLight", "png"), ("AppIconDark", "png"),
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
      visibleScreenHeight: store.visibleScreenHeight)
  }

  private func configureButton() {
    guard let button = statusItem.button else { return }
    button.image = AIManagerBrand.trayImage(in: bundle)
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(statusItemClicked)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  /// Right-click menu of the status item: open the app, refresh, Settings, Quit.
  func makeContextMenu() -> NSMenu {
    let name = AIManagerBrand.bundleDisplayName(in: bundle)
    let menu = NSMenu(title: name)
    let items: [(String, Selector, String)] = [
      ("Open \(name)", #selector(contextOpen), ""),
      ("Refresh Usage", #selector(contextRefresh), ""),
      ("Settings…", #selector(contextSettings), ","),
    ]
    for (title, action, key) in items {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = self
      menu.addItem(item)
    }
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(
      title: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    return menu
  }

  @objc private func contextOpen() { store.openMainWindow() }
  @objc private func contextRefresh() { Task { await store.refreshUsage() } }
  @objc private func contextSettings() { store.actions.openSettings() }

  @objc private func statusItemClicked() {
    guard NSApp.currentEvent?.type == .rightMouseUp else {
      togglePopover()
      return
    }
    if popover.isShown { closePopover() }
    // A menu on the item makes the next click open it; remove it again right away.
    statusItem.menu = makeContextMenu()
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  /// The global shortcut opens or closes the popover like a click on the status item.
  func togglePopoverFromShortcut() { togglePopover() }

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
      return "\(account.providerID.guiName), \(account.identity), \(quota)"
    }.joined(separator: "\n")
    button.toolTip = description.isEmpty ? applicationName : description
    button.setAccessibilityLabel(
      description.isEmpty ? applicationName : applicationName + ", " + description)
  }

  #if AI_MANAGER_PREVIEW
  /// Opens the popover without a click, for Preview screenshots.
  func showPopoverForPreview() {
    if !popover.isShown { togglePopover() }
  }
  #endif

  @objc private func togglePopover() {
    if popover.isShown {
      closePopover()
      return
    }
    guard let button = statusItem.button else { return }
    resizePopover()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    resizePopover()
    if PopoverRefreshPreference.isEnabled(defaults: defaults) { Task { await store.refreshUsage() } }
  }

  private func closePopover() {
    popover.performClose(nil)
  }
}
