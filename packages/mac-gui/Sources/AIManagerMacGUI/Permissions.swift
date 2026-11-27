import AppKit
import SamPermissions

/// The one file that talks to SamPermissions. Like CrashReports.swift, only AIManagerApp.swift calls it,
/// so the Preview and lint builds compile without the package and their Settings buttons do nothing.
@MainActor
enum Permissions {
  static func start() {
    SamPermissions.shared.handleLaunch()
    SystemSettingsGuide.open = { page in
      // The click point in screen coordinates: the guide panel flies out of the pressed button.
      let click = CGRect(origin: NSEvent.mouseLocation, size: .zero)
      switch page {
      case .notifications: SamPermissions.shared.guide(.notifications, from: click)
      case .loginItems: SamPermissions.shared.guide(.loginItems, from: click)
      }
    }
  }
}
