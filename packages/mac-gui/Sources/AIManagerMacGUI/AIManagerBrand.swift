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
  var statusTitle: String { statusItem.button?.title ?? "" }

  private let statusItem: NSStatusItem
  private let popover = NSPopover()
  private let store: MenuBarPopoverStore
  private let bundle: Bundle

  init(
    bundle: Bundle = .main,
    snapshot: MenuBarSnapshot = .empty,
    actions: MenuBarPopoverActions
  ) {
    self.bundle = bundle
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    store = MenuBarPopoverStore(snapshot: snapshot, actions: actions)
    super.init()

    let content = MenuBarPopover(store: store)
    popover.behavior = .transient
    popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    popover.contentViewController = NSHostingController(rootView: content)
    popover.contentSize = Self.contentSize(
      accountCount: snapshot.accounts.count,
      visibleScreenHeight: NSScreen.main?.visibleFrame.height ?? Self.fallbackScreenHeight)

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
    updateStatusLabel(snapshot.primaryUsedPercentage)
    if popover.isShown {
      popover.contentSize = Self.contentSize(
        accountCount: snapshot.accounts.count,
        visibleScreenHeight: statusItem.button?.window?.screen?.visibleFrame.height
          ?? NSScreen.main?.visibleFrame.height
          ?? Self.fallbackScreenHeight)
    }
  }

  func updateAppearance(_ appearance: NSAppearance?) {
    popover.appearance = appearance
    popover.contentViewController?.view.appearance = appearance
  }

  static func contentSize(accountCount: Int, visibleScreenHeight: CGFloat) -> NSSize {
    let visibleRows = min(max(accountCount, 0), MenuBarPopover.maximumVisibleRows)
    let idealHeight = MenuBarPopover.headerHeight
      + MenuBarPopover.footerHeight
      + CGFloat(visibleRows) * MenuBarPopover.accountRowHeight
    let screenMaximum = max(MenuBarPopover.minimumHeight, visibleScreenHeight - 96)
    let height = min(
      max(idealHeight, MenuBarPopover.minimumHeight),
      min(MenuBarPopover.maximumHeight, screenMaximum))
    return NSSize(width: MenuBarPopover.width, height: height)
  }

  private static let fallbackScreenHeight: CGFloat = 900

  private func configureButton() {
    guard let button = statusItem.button else { return }
    button.image = AIManagerBrand.trayImage(in: bundle)
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(togglePopover)
    button.sendAction(on: [.leftMouseUp])
  }

  private func updateStatusLabel(_ usedPercentage: Int?) {
    guard let button = statusItem.button else { return }
    let applicationName = AIManagerBrand.bundleDisplayName(in: bundle)
    if let usedPercentage {
      button.title = "\(usedPercentage)%"
      button.imagePosition = .imageLeading
      button.toolTip = "\(applicationName) — \(usedPercentage)% used quota"
      button.setAccessibilityLabel("\(applicationName), \(usedPercentage) percent used quota")
    } else {
      button.title = ""
      button.imagePosition = .imageOnly
      button.toolTip = applicationName
      button.setAccessibilityLabel(applicationName)
    }
  }

  @objc private func togglePopover() {
    if popover.isShown {
      closePopover()
      return
    }
    guard let button = statusItem.button else { return }
    popover.contentSize = Self.contentSize(
      accountCount: store.snapshot.accounts.count,
      visibleScreenHeight: button.window?.screen?.visibleFrame.height
        ?? NSScreen.main?.visibleFrame.height
        ?? Self.fallbackScreenHeight)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  private func closePopover() {
    popover.performClose(nil)
  }
}
