import AIManagerCore
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
  @MainActor static func menuBarPopoverFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }

    expect(MenuBarPopover.width == 360, "Menu-bar popover is not 360 points wide")
    expect(MenuBarPopover.minimumHeight == 192, "Menu-bar popover minimum height is not 192 points")
    expect(MenuBarPopover.maximumHeight == 536, "Menu-bar popover maximum height is not 536 points")
    expect(MenuBarPopover.accountRowHeight == 60, "Menu-bar account rows are not 60 points high")
    expect(MenuBarPopover.maximumVisibleRows == 6, "Menu-bar account list does not stop at six visible rows")

    let empty = AIManagerStatusItemController.contentSize(accountCount: 0, visibleScreenHeight: 900)
    let one = AIManagerStatusItemController.contentSize(accountCount: 1, visibleScreenHeight: 900)
    let six = AIManagerStatusItemController.contentSize(accountCount: 6, visibleScreenHeight: 900)
    let many = AIManagerStatusItemController.contentSize(accountCount: 20, visibleScreenHeight: 900)
    let shortScreen = AIManagerStatusItemController.contentSize(accountCount: 20, visibleScreenHeight: 480)
    for size in [empty, one, six, many, shortScreen] {
      expect(size.width == 360, "Menu-bar popover width changes with its contents")
      expect(size.height >= 192, "Menu-bar popover is shorter than 192 points")
      expect(size.height <= 536, "Menu-bar popover is taller than 536 points")
    }
    expect(empty.height == 192, "Empty menu-bar popover does not use its compact minimum height")
    expect(one.height == 236, "One-row menu-bar popover has the wrong fixed-region geometry")
    expect(six.height == 536 && many.height == six.height, "Menu-bar list does not scroll after six rows")
    expect(shortScreen.height == 384, "Menu-bar popover does not honor the visible-screen inset")

    let snapshot = MenuBarPopoverPreviewData.snapshot
    expect(snapshot.primaryUsedPercentage == 42, "Preview menu snapshot lacks cached primary usage")
    expect(snapshot.accounts.count == 3, "Preview menu snapshot does not exercise account states")
    expect(snapshot.accounts.first?.isActive == true, "Preview menu snapshot lacks an active account")
    expect(snapshot.accounts.contains(where: { !$0.isVerified }), "Preview menu snapshot lacks an unavailable row")
    expect(snapshot.accounts.compactMap(\.usage).contains(where: {
      $0.plan != nil && $0.resetDescription != nil
    }), "Preview menu snapshot lacks cached plan and reset details")

    let controller = AIManagerStatusItemController(
      snapshot: snapshot,
      actions: MenuBarPopoverActions(
        openMainWindow: {}, addAccount: {}, quit: {}, switchAccount: { _ in }))
    expect(controller.isPresent, "Menu-bar template mark is unavailable")
    expect(controller.usesPopover, "Status item still uses a static menu")
    expect(controller.popoverContentSize.width == 360, "Hosted popover changed its fixed width")
    expect(controller.statusTitle == "42%", "Status item does not show cached primary usage")
    controller.update(snapshot: .empty)
    expect(controller.statusTitle.isEmpty, "Status item is not icon-only when usage is unavailable")
    return failures
  }

  static func chatPresentationFailures() -> [String] {
    var failures: [String] = []
    let markdown = """
      # Heading

      A **bold** paragraph.

      > Quoted text

      - First
      - Second

      1. One
      2. Two

      ```swift
      let answer = 42
      ```
      """
    let message = ChatMessage(id: "markdown", role: .assistant, text: markdown, timestamp: nil)
    do {
      let presentation = try ChatMessagePresenter.parse(message)
      if !presentation.blocks.contains(where: { if case .heading = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve a Markdown heading")
      }
      if !presentation.blocks.contains(where: { if case .quote = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve a Markdown quote")
      }
      if !presentation.blocks.contains(where: { if case .unorderedList = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve an unordered list")
      }
      if !presentation.blocks.contains(where: { if case .orderedList = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve an ordered list")
      }
      if !presentation.blocks.contains(where: {
        if case let .code(_, language, text, _, _) = $0 {
          return language == "swift" && text == "let answer = 42"
        }
        return false
      }) {
        failures.append("Chat presentation did not preserve a fenced Swift code block")
      }
    } catch {
      failures.append("Chat presentation could not parse structured Markdown: \(error)")
    }

    let longCode = (0..<30).map { "line \($0)" }.joined(separator: "\n")
    let bounded = ChatMessage(
      id: "bounded", role: .assistant,
      text: "```text\n\(longCode)\n```\n"
        + String(repeating: "x", count: ChatMessagePresenter.maximumSourceCharacters + 1),
      timestamp: nil)
    do {
      let presentation = try ChatMessagePresenter.parse(bounded)
      if !presentation.sourceWasTruncated {
        failures.append("Chat presentation did not report its source bound")
      }
      if !presentation.blocks.contains(where: {
        if case let .code(_, _, preview, expanded, _) = $0 {
          return preview.split(separator: "\n").count == ChatMessagePresenter.compactCodeLines
            && expanded != nil
        }
        return false
      }) {
        failures.append("Chat presentation did not compact long code")
      }
    } catch {
      failures.append("Chat presentation could not apply its content bounds: \(error)")
    }
    return failures
  }

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
    if abs(AIMTheme.historyRailIconSize - (AIMTheme.railIconSize * 0.75)) > 0.001 {
      failures.append("The Chat History rail symbol is not 25 percent smaller")
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

  static func windowPlacementFailures() -> [String] {
    var failures: [String] = []
    let size = NSSize(width: 1120, height: 740)
    let primary = AIManagerDisplayDescriptor(
      identifier: "primary", name: "Built-in Display",
      frame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
      visibleFrame: NSRect(x: 0, y: 38, width: 1728, height: 1054))
    let external = AIManagerDisplayDescriptor(
      identifier: "external", name: "External Display",
      frame: NSRect(x: -2560, y: 120, width: 2560, height: 1440),
      visibleFrame: NSRect(x: -2560, y: 120, width: 2560, height: 1416))
    let original = NSRect(x: -2200, y: 620, width: size.width, height: size.height)
    let placement = AIManagerWindowPlacement.placement(for: original, on: external)
    if AIManagerWindowPlacement.restoredFrame(
      for: placement, windowSize: size, displays: [primary, external]) != original
    {
      failures.append("Window placement does not restore a negative-coordinate display")
    }

    let rearrangedExternal = AIManagerDisplayDescriptor(
      identifier: "external", name: "External Display",
      frame: NSRect(x: 1728, y: -400, width: 2560, height: 1440),
      visibleFrame: NSRect(x: 1728, y: -400, width: 2560, height: 1416))
    let expectedRearranged = NSRect(x: 2088, y: 100, width: size.width, height: size.height)
    if AIManagerWindowPlacement.restoredFrame(
      for: placement, windowSize: size, displays: [primary, rearrangedExternal])
      != expectedRearranged
    {
      failures.append("Window placement does not follow a rearranged saved display")
    }
    if AIManagerWindowPlacement.restoredFrame(
      for: placement, windowSize: size, displays: [primary]) != nil
    {
      failures.append("Window placement falls back to the wrong display")
    }

    let legacy = "-2200 620 1120 740 -2560 120 2560 1410"
    if AIManagerWindowPlacement.legacyPlacement(
      from: legacy, displays: [primary, external]) != placement
    {
      failures.append("Legacy AppKit placement does not tolerate usable-frame changes")
    }
    let unrelatedLegacy = "7000 7000 1120 740 7000 7000 2560 1440"
    if AIManagerWindowPlacement.legacyPlacement(
      from: unrelatedLegacy, displays: [primary, external]) != nil
    {
      failures.append("Legacy AppKit placement migrates to an unrelated display")
    }

    let domain = "com.mandalsuraj.ai-manager.acceptance.window-placement"
    if let defaults = UserDefaults(suiteName: domain) {
      defaults.removePersistentDomain(forName: domain)
      AIManagerWindowPlacement.store(placement, defaults: defaults)
      if AIManagerWindowPlacement.load(defaults: defaults) != placement {
        failures.append("Window placement does not persist through UserDefaults")
      }
      defaults.removePersistentDomain(forName: domain)
    } else {
      failures.append("Window placement test defaults are unavailable")
    }

    let farOutside = AIManagerStoredWindowPlacement(
      version: 1, displayIdentifier: "external", displayName: "External Display",
      displayFrameX: external.frame.minX, displayFrameY: external.frame.minY,
      displayFrameWidth: external.frame.width, displayFrameHeight: external.frame.height,
      leftOffset: 99_999, topOffset: 99_999)
    guard let clamped = AIManagerWindowPlacement.restoredFrame(
      for: farOutside, windowSize: size, displays: [external])
    else {
      failures.append("Window placement did not produce a clamped frame")
      return failures
    }
    if !external.visibleFrame.contains(clamped) {
      failures.append("Window placement did not clamp into the display visible frame")
    }
    return failures
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
      $0.autohidesScrollers && $0.verticalScroller is AIMThinScroller
        && ($0.scrollerStyle == .overlay
          || abs($0.contentView.frame.width - $0.bounds.width) < 1)
    }.count
  }

  static func historySearchFieldsMatch(in root: NSView) -> Bool {
    let placeholders = Set(views(in: root).compactMap {
      ($0 as? NSTextField)?.placeholderString
    })
    return placeholders.contains("Search conversations") && placeholders.contains("Search this chat")
  }

  static func virtualHistoryScrollCount(in root: NSView) -> Int {
    views(in: root).filter { $0 is AIMVirtualTableView }.count
  }

  static func realizedVirtualRowCount(in root: NSView) -> Int {
    views(in: root).filter { $0 is NSTableRowView }.count
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
