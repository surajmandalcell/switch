import AppKit

enum AIManagerPage: String, CaseIterable {
  case accounts = "Accounts"
  case backup = "Backup"
  case history = "Chat History"
  case settings = "Shared Settings"
}

enum AIManagerNavigation {
  static let request = Notification.Name("AIManagerNavigationRequest")
  static let didShowPage = Notification.Name("AIManagerNavigationDidShowPage")
}

@MainActor
final class AIManagerMenuController: NSObject, NSMenuItemValidation {
  private let applicationName: String
  private let addAccount: () -> Void
  private let advancedImport: () -> Void
  private let closeWindow: () -> Void
  private let minimizeWindow: () -> Void
  private let presentWindow: () -> Void
  private let canChangeAccounts: () -> Bool

  init(
    applicationName: String,
    addAccount: @escaping () -> Void,
    advancedImport: @escaping () -> Void,
    closeWindow: @escaping () -> Void,
    minimizeWindow: @escaping () -> Void,
    presentWindow: @escaping () -> Void,
    canChangeAccounts: @escaping () -> Bool
  ) {
    self.applicationName = applicationName
    self.addAccount = addAccount
    self.advancedImport = advancedImport
    self.closeWindow = closeWindow
    self.minimizeWindow = minimizeWindow
    self.presentWindow = presentWindow
    self.canChangeAccounts = canChangeAccounts
  }

  func install() {
    let mainMenu = NSMenu()
    mainMenu.addItem(parentMenu(applicationName, items: applicationItems()))
    mainMenu.addItem(parentMenu("File", items: fileItems()))
    mainMenu.addItem(parentMenu("Edit", items: editItems()))
    mainMenu.addItem(parentMenu("View", items: viewItems()))

    let windowMenu = parentMenu("Window", items: windowItems())
    mainMenu.addItem(windowMenu)
    NSApp.windowsMenu = windowMenu.submenu

    let helpMenu = parentMenu("Help", items: helpItems())
    mainMenu.addItem(helpMenu)
    NSApp.helpMenu = helpMenu.submenu
    NSApp.mainMenu = mainMenu
  }

  @objc func showSettings(_ sender: Any?) { navigate(to: .settings) }
  @objc func showAccounts(_ sender: Any?) { navigate(to: .accounts) }
  @objc func showBackup(_ sender: Any?) { navigate(to: .backup) }
  @objc func showChatHistory(_ sender: Any?) { navigate(to: .history) }
  @objc func performAddAccount(_ sender: Any?) { addAccount() }
  @objc func performAdvancedImport(_ sender: Any?) { advancedImport() }
  @objc func performClose(_ sender: Any?) { closeWindow() }
  @objc func performMinimize(_ sender: Any?) { minimizeWindow() }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    [#selector(performAddAccount(_:)), #selector(performAdvancedImport(_:))].contains(menuItem.action)
      ? canChangeAccounts() : true
  }

  private func navigate(to page: AIManagerPage) {
    presentWindow()
    NSApp.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
  }

  private func applicationItems() -> [NSMenuItem] {
    let services = NSMenu(title: "Services")
    let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    servicesItem.submenu = services
    NSApp.servicesMenu = services
    return [
      item("About \(applicationName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
      .separator(),
      item("Settings…", #selector(showSettings(_:)), key: ",", target: self),
      .separator(),
      servicesItem,
      .separator(),
      item("Hide \(applicationName)", #selector(NSApplication.hide(_:)), key: "h", target: NSApp),
      item(
        "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
        modifiers: [.command, .option], target: NSApp),
      item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
      .separator(),
      item("Quit \(applicationName)", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp),
    ]
  }

  private func fileItems() -> [NSMenuItem] {
    [
      item("Add Account…", #selector(performAddAccount(_:)), key: "n", target: self),
      item(
        "Advanced Import…", #selector(performAdvancedImport(_:)), key: "i",
        modifiers: [.command, .shift], target: self),
      .separator(),
      item("Close Window", #selector(performClose(_:)), key: "w", target: self),
    ]
  }

  private func editItems() -> [NSMenuItem] {
    [
      item("Undo", Selector(("undo:")), key: "z"),
      item("Redo", Selector(("redo:")), key: "Z"),
      .separator(),
      item("Cut", #selector(NSText.cut(_:)), key: "x"),
      item("Copy", #selector(NSText.copy(_:)), key: "c"),
      item("Paste", #selector(NSText.paste(_:)), key: "v"),
      item(
        "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), key: "V",
        modifiers: [.command, .option, .shift]),
      item("Delete", #selector(NSText.delete(_:)), key: "\u{8}", modifiers: []),
      item("Select All", #selector(NSText.selectAll(_:)), key: "a"),
    ]
  }

  private func viewItems() -> [NSMenuItem] {
    [
      item("Accounts", #selector(showAccounts(_:)), key: "1", target: self),
      item("Backup", #selector(showBackup(_:)), key: "2", target: self),
      item("Chat History", #selector(showChatHistory(_:)), key: "3", target: self),
      item("Shared Settings", #selector(showSettings(_:)), key: "4", target: self),
    ]
  }

  private func windowItems() -> [NSMenuItem] {
    [
      item("Minimize", #selector(performMinimize(_:)), key: "m", target: self),
      .separator(),
      item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp),
    ]
  }

  private func helpItems() -> [NSMenuItem] {
    [item("\(applicationName) Help", #selector(NSApplication.showHelp(_:)), key: "?", target: NSApp)]
  }

  private func parentMenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: title)
    items.forEach(submenu.addItem)
    parent.submenu = submenu
    return parent
  }

  private func item(
    _ title: String,
    _ action: Selector?,
    key: String = "",
    modifiers: NSEvent.ModifierFlags = .command,
    target: AnyObject? = nil
  ) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
    menuItem.keyEquivalentModifierMask = modifiers
    menuItem.target = target
    return menuItem
  }
}
