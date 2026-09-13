import AppKit

struct AIManagerNativeViewSnapshot: Codable {
  let path: String
  let className: String
  let frameX: Double
  let frameY: Double
  let frameWidth: Double
  let frameHeight: Double
  let isFlipped: Bool
  let focusRingType: UInt
  let scrollStyle: String?
  let autohidesScrollers: Bool?
  let verticalScrollerClass: String?
}

@MainActor
enum AIManagerNativeContract {
  @MainActor static func menuFailures(in mainMenu: NSMenu?, applicationName: String) -> [String] {
    guard let mainMenu else { return ["Main menu is unavailable"] }
    var failures: [String] = []
    let expectedPages = ["Accounts", "Backup", "Chat History", "Shared Settings"]
    if AIManagerPage.allCases.map(\.rawValue) != expectedPages {
      failures.append("The rail and View menu page order is incorrect")
    }
    if AIMIcon.Name.history.symbol != "bubble.left.and.bubble.right"
      || NSImage(systemSymbolName: AIMIcon.Name.history.symbol, accessibilityDescription: nil) == nil
    {
      failures.append("Chat History does not use the required system chat symbol")
    }
    let expectedMenus = [applicationName, "File", "Edit", "View", "Window", "Help"]
    if mainMenu.items.map(\.title) != expectedMenus {
      failures.append("Main menu order does not match the native menu contract")
    }
    func command(_ menu: String, _ title: String, key: String, modifiers: NSEvent.ModifierFlags = .command) {
      guard let item = mainMenu.item(withTitle: menu)?.submenu?.item(withTitle: title) else {
        failures.append("\(menu) > \(title) is missing")
        return
      }
      if item.keyEquivalent != key || item.keyEquivalentModifierMask != modifiers {
        failures.append("\(menu) > \(title) has the wrong key equivalent")
      }
    }
    func nativeCommand(_ menu: String, _ title: String, action: Selector) {
      guard let item = mainMenu.item(withTitle: menu)?.submenu?.item(withTitle: title) else {
        failures.append("\(menu) > \(title) is missing")
        return
      }
      if item.action != action { failures.append("\(menu) > \(title) does not use the native action") }
    }
    command(applicationName, "Settings…", key: ",")
    command(applicationName, "Quit \(applicationName)", key: "q")
    command("File", "Import Account…", key: "i")
    command("File", "Close Window", key: "w")
    command("Window", "Minimize", key: "m")
    for (index, page) in AIManagerPage.allCases.enumerated() {
      command("View", page.rawValue, key: String(index + 1))
    }
    for (menu, title, action) in [
      (applicationName, "About \(applicationName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
      (applicationName, "Hide \(applicationName)", #selector(NSApplication.hide(_:))),
      (applicationName, "Hide Others", #selector(NSApplication.hideOtherApplications(_:))),
      (applicationName, "Show All", #selector(NSApplication.unhideAllApplications(_:))),
      (applicationName, "Quit \(applicationName)", #selector(NSApplication.terminate(_:))),
      ("Edit", "Cut", #selector(NSText.cut(_:))),
      ("Edit", "Copy", #selector(NSText.copy(_:))),
      ("Edit", "Paste", #selector(NSText.paste(_:))),
      ("Edit", "Select All", #selector(NSText.selectAll(_:))),
      ("Window", "Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
      ("Help", "\(applicationName) Help", #selector(NSApplication.showHelp(_:))),
    ] {
      nativeCommand(menu, title, action: action)
    }
    if mainMenu.item(withTitle: applicationName)?.submenu?.item(withTitle: "Services")?.submenu !== NSApp.servicesMenu {
      failures.append("The application Services menu is not registered")
    }
    if mainMenu.item(withTitle: "Window")?.submenu !== NSApp.windowsMenu {
      failures.append("The Window menu is not registered with AppKit")
    }
    if mainMenu.item(withTitle: "Help")?.submenu !== NSApp.helpMenu {
      failures.append("The Help menu is not registered with AppKit")
    }
    let windowItems = mainMenu.item(withTitle: "Window")?.submenu?.items ?? []
    if windowItems.contains(where: { $0.action == #selector(NSWindow.performZoom(_:)) || $0.title.contains("Zoom") }) {
      failures.append("The fixed window exposes a maximize command")
    }
    return failures
  }

  @MainActor static func exerciseMenuNavigation(in window: NSWindow?) -> [String] {
    guard let mainMenu = NSApp.mainMenu, let window else { return ["Menu navigation test could not resolve the app window"] }
    var failures: [String] = []
    var shownPages: [AIManagerPage] = []
    let observer = NotificationCenter.default.addObserver(
      forName: AIManagerNavigation.didShowPage, object: nil, queue: .main
    ) { notification in
      if let page = notification.object as? AIManagerPage { shownPages.append(page) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    window.orderOut(nil)
    let settings = mainMenu.item(withTitle: mainMenu.items[0].title)?.submenu?.item(withTitle: "Settings…")
    if let settings, let action = settings.action {
      if !NSApp.sendAction(action, to: settings.target, from: settings) {
        failures.append("Command+, could not dispatch its action")
      }
    } else {
      failures.append("Command+, could not resolve its menu item")
    }
    if !window.isVisible { failures.append("Command+, did not bring the main window forward") }
    if shownPages.last != .settings { failures.append("Command+, did not navigate to Shared Settings") }

    for page in AIManagerPage.allCases {
      guard let item = mainMenu.item(withTitle: "View")?.submenu?.item(withTitle: page.rawValue),
            let action = item.action else {
        failures.append("View > \(page.rawValue) could not resolve its action")
        continue
      }
      _ = NSApp.sendAction(action, to: item.target, from: item)
      if shownPages.last != page { failures.append("View > \(page.rawValue) did not navigate") }
    }
    return failures
  }

  // Acceptance points use the screenshot's top-left origin; AppKit content views usually do not.
  static func titleDragTarget(in window: NSWindow, at point: NSPoint) -> Bool {
    guard let contentView = window.contentView else { return false }
    return hitTest(in: contentView, atTopOriginPoint: point) is AIMTitleDragView
  }

  static func focusPolicyMatches(in root: NSView, indicatorsEnabled: Bool) -> Bool {
    root.focusRingType == (indicatorsEnabled ? .default : .none)
  }

  static func defaultFocusIndicatorsAreHidden(in window: NSWindow) -> Bool {
    window.contentView?.focusRingType == NSFocusRingType.none
  }

  static func windowControlGeometryMatches() -> Bool {
    let size = AIMTheme.windowControlSize
    return size == 48 && AIMTheme.railWidth == size
      && AIMTheme.topbarHeight == size && AIMTheme.modalTitlebarHeight == size
      && AIMTheme.modalHeight == 648 && AIMTheme.modalOuterInset == 24
      && AIMTheme.modalSectionSpacing == 16
  }

  static func scrollBehaviorIsInstalled(in root: NSView) -> Bool {
    let scrollViews = views(in: root).compactMap { $0 as? NSScrollView }
    return !scrollViews.isEmpty && configuredScrollViewCount(in: root) == scrollViews.count
      && scrollViews.allSatisfy { scroll in
        guard let document = scroll.documentView else { return false }
        return document.frame.height > 0 && scroll.contentView.bounds.height > 0
          && abs(document.frame.width - scroll.contentView.bounds.width) < 1
          && abs(scroll.contentView.frame.width - scroll.bounds.width) < 1
      }
  }

  static func configuredScrollViewCount(in root: NSView) -> Int {
    views(in: root).compactMap { $0 as? NSScrollView }.filter {
      $0.scrollerStyle == .overlay && $0.autohidesScrollers
        && $0.verticalScroller is AIMThinScroller
    }.count
  }

  static func scrollAppearancesMatch(in root: NSView, appearance: NSAppearance) -> Bool {
    views(in: root).compactMap { $0 as? NSScrollView }.allSatisfy {
      $0.documentView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        == appearance.bestMatch(from: [.darkAqua, .aqua])
    }
  }

  static func scrollIdentity(in root: NSView) -> String {
    views(in: root).compactMap { $0 as? NSScrollView }
      .map { String(describing: ObjectIdentifier($0)) }.joined(separator: ",")
  }

  static func hasVisualEffect(in root: NSView) -> Bool {
    views(in: root).contains { $0 is NSVisualEffectView }
  }

  static func hierarchySnapshot(in root: NSView) -> [AIManagerNativeViewSnapshot] {
    snapshot(view: root, path: "0")
  }

  static func hitTestPath(in window: NSWindow, atTopOriginPoint point: NSPoint) -> [String] {
    guard let contentView = window.contentView else { return [] }
    var current = hitTest(in: contentView, atTopOriginPoint: point)
    var path: [String] = []
    while let view = current {
      path.append(
        "\(NSStringFromClass(type(of: view))) frame=\(NSStringFromRect(view.frame)) flipped=\(view.isFlipped)"
      )
      current = view.superview
    }
    return path
  }

  private static func views(in root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { views(in: $0) }
  }

  private static func snapshot(view: NSView, path: String) -> [AIManagerNativeViewSnapshot] {
    let scrollView = view as? NSScrollView
    let item = AIManagerNativeViewSnapshot(
      path: path,
      className: NSStringFromClass(type(of: view)),
      frameX: view.frame.minX,
      frameY: view.frame.minY,
      frameWidth: view.frame.width,
      frameHeight: view.frame.height,
      isFlipped: view.isFlipped,
      focusRingType: view.focusRingType.rawValue,
      scrollStyle: scrollView.map { $0.scrollerStyle == .overlay ? "overlay" : "legacy" },
      autohidesScrollers: scrollView?.autohidesScrollers,
      verticalScrollerClass: scrollView?.verticalScroller.map { NSStringFromClass(type(of: $0)) }
    )
    return [item]
      + view.subviews.enumerated().flatMap { index, child in
        snapshot(view: child, path: "\(path).\(index)")
      }
  }

  private static func appKitPoint(fromTopOrigin point: NSPoint, in view: NSView) -> NSPoint {
    view.isFlipped ? point : NSPoint(x: point.x, y: view.bounds.height - point.y)
  }

  private static func hitTest(in view: NSView, atTopOriginPoint point: NSPoint) -> NSView? {
    let localPoint = appKitPoint(fromTopOrigin: point, in: view)
    let pointForHitTest = view.superview.map { view.convert(localPoint, to: $0) } ?? localPoint
    return view.hitTest(pointForHitTest)
  }
}
