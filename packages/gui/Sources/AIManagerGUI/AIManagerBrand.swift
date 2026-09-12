import AppKit

@MainActor
enum AIManagerBrand {
  static let traySize = NSSize(width: 22, height: 22)

  static func installApplicationIcon(in bundle: Bundle = .main) {
    if let image = image(named: "AppIcon", extension: "png", bundle: bundle) {
      NSApp.applicationIconImage = image
    }
  }

  static func railMark(in bundle: Bundle = .main) -> NSImage? {
    guard let image = image(named: "ManagerMark", extension: "png", bundle: bundle) else {
      return nil
    }
    image.isTemplate = true
    return image
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
      ("AppIcon", "icns"), ("AppIcon", "png"), ("ManagerMark", "png"),
      ("TrayTemplate", "png"), ("TrayTemplate@2x", "png"),
    ] where resourceURL(named: name, extension: fileExtension, bundle: bundle) == nil {
      failures.append("Brand asset \(name).\(fileExtension) is unavailable")
    }
    guard let rail = railMark(in: bundle) else {
      failures.append("Rail brand mark did not load")
      return failures
    }
    if !rail.isTemplate { failures.append("Rail brand mark is not a template image") }
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

  private let statusItem: NSStatusItem
  private let showWindow: () -> Void

  init(
    bundle: Bundle = .main,
    showWindow: @escaping () -> Void
  ) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    self.showWindow = showWindow
    super.init()

    statusItem.button?.image = AIManagerBrand.trayImage(in: bundle)
    statusItem.button?.imagePosition = .imageOnly
    let title = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "IIA Directeur"
    statusItem.button?.toolTip = title
    statusItem.button?.setAccessibilityLabel(title)

    let menu = NSMenu()
    let showItem = NSMenuItem(title: "Show IIA Directeur", action: #selector(show), keyEquivalent: "")
    showItem.target = self
    menu.addItem(showItem)
    let quitItem = NSMenuItem(title: "Quit", action: #selector(terminate), keyEquivalent: "")
    quitItem.target = self
    menu.addItem(quitItem)
    statusItem.menu = menu
  }

  deinit {
    let item = statusItem
    Task { @MainActor in NSStatusBar.system.removeStatusItem(item) }
  }

  @objc private func show() { showWindow() }
  @objc private func terminate() { NSApp.terminate(nil) }
}
