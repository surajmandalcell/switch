import AIManagerCore
import AppKit
import SwiftUI

/// Choose Bars: which usage bars one service shows in the popover's collapsed row and expanded row.
/// A small window, so it opens the same way from the popover and from the Accounts page.
@MainActor
enum MenuBarBarsDialog {
  /// The popover store, set by the status item: the dialog reads the service's accounts from it.
  static weak var store: MenuBarPopoverStore?
  private static var window: NSWindow?

  static func show(_ provider: ProviderID) {
    guard let store else { return }
    window?.close()
    let host = NSHostingController(rootView: MenuBarBarsSheet(provider: provider, store: store) {
      Self.window?.close()
    }.focusEffectDisabled(!AIMFocus.showsSystemRings))
    host.sizingOptions = [.preferredContentSize]
    let window = NSWindow(contentViewController: host)
    window.styleMask = [.titled, .closable, .fullSizeContentView]
    window.title = "Bars for \(provider.guiName)"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.backgroundColor = AIMTheme.pageColor
    window.identifier = NSUserInterfaceItemIdentifier("menu-bar-bars")
    window.center()
    Self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
}

struct MenuBarBarsSheet: View {
  let provider: ProviderID
  @ObservedObject var store: MenuBarPopoverStore
  let close: () -> Void
  @State private var choices: MenuBarBarChoices
  @AppStorage(UsagePercentagePreferences.showsUsedKey) private var showsUsed = false
  private typealias P = MenuBarPresentation
  static let eyeWidth: CGFloat = 84

  init(provider: ProviderID, store: MenuBarPopoverStore, choices: MenuBarBarChoices? = nil,
       close: @escaping () -> Void) {
    self.provider = provider
    self.store = store
    self.close = close
    _choices = State(initialValue: choices ?? MenuBarBarPreferences.choices(for: provider))
  }

  private var accounts: [MenuBarAccountSnapshot] {
    store.snapshot.accounts.filter { $0.providerID == provider && $0.usage != nil }.map {
      var account = $0
      account.barChoices = choices
      return account
    }
  }

  var body: some View {
    let states = MenuBarBarsState.rows(accounts, choices)
    let glanceCount = states.filter(\.glance).count
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: AIMTheme.sectionSpacing) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Bars for \(provider.guiName)").aimText(.section)
          Text("Pick the bars the menu bar shows for this service.").aimText(.secondary)
        }
        preview
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            Text("Bar").frame(maxWidth: .infinity, alignment: .leading)
            Text("At a glance").frame(width: Self.eyeWidth)
            Text("Expanded").frame(width: Self.eyeWidth)
          }
          .aimText(.caption, tint: P.secondaryInk)
          .padding(.horizontal, 12).frame(height: 26)
          ForEach(Array(states.enumerated()), id: \.element.title) { index, state in
            AIMHairline()
            HStack(spacing: 0) {
              Text(state.title).aimText(.body).lineLimit(1).truncationMode(.tail).help(state.title)
                .frame(maxWidth: .infinity, alignment: .leading)
              eye(state.glance, view: "at a glance", title: state.title,
                disabled: state.glance && glanceCount == 1 ? "One bar always stays at a glance" : nil) {
                choices.glance[state.title] = !state.glance
              }
              eye(state.expanded, view: "expanded", title: state.title,
                disabled: state.glance ? "Bars at a glance also show when expanded" : nil) {
                choices.expanded[state.title] = !state.expanded
              }
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(index.isMultiple(of: 2) ? Color.clear : AIMTheme.rowHover)
          }
        }
        .background(AIMTheme.container, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .aimBorder(AIMTheme.controlBorder, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        if states.isEmpty {
          Text("No usage yet. Bars show here once usage arrives.").aimText(.secondary)
        }
      }
      .padding(AIMTheme.pageMargin)
      .padding(.top, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      AIMHairline()
      HStack(spacing: AIMTheme.rowSpacing) {
        AIMButton(title: "Reset to Default", disabled: choices.isDefault) { choices = MenuBarBarChoices() }
        Spacer()
        AIMButton(title: "Done", tone: .primary, action: close)
          .keyboardShortcut(.defaultAction)
      }
      .padding(AIMTheme.cardInset)
    }
    .frame(width: 440)
    .fixedSize(horizontal: false, vertical: true)
    .background(AIMTheme.page)
    .onChange(of: choices) { _, choices in MenuBarBarPreferences.set(choices, for: provider) }
  }

  /// The collapsed row of the first account (the default one first) with the picks applied.
  @ViewBuilder private var preview: some View {
    let account = accounts.first(where: \.isActive) ?? accounts.first
    let lines = account.map { P.lines(for: $0) } ?? []
    if let account, !lines.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("At a glance").aimText(.caption, tint: P.secondaryInk)
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          HStack(spacing: 6) {
            Text(line.isHeading ? (line.label ?? "") : (P.displayLabel(line) ?? ""))
              .aimText(line.isHeading ? .caption : .secondary, tint: P.secondaryInk).lineLimit(1)
              .frame(width: 72, alignment: .leading)
            if !line.isHeading {
              if let balance = line.balance {
                Text(balance).aimText(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
              } else {
                UsageBar(usedPercent: line.used.map(Double.init), showsUsed: showsUsed, providerID: account.providerID)
                  .frame(height: UsageBar.height)
                Text(line.used.map { "\(UsagePercentagePreferences.displayedPercentage(forUsed: $0, showsUsed: showsUsed))%" } ?? "—")
                  .aimText(.secondary, tint: P.secondaryInk).monospacedDigit()
                  .frame(width: P.percentWidth, alignment: .trailing)
              }
            } else { Spacer(minLength: 0) }
          }
          .frame(height: P.lineHeight)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AIMTheme.container, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .aimBorder(AIMTheme.controlBorder, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Preview")
    }
  }

  private func eye(_ shown: Bool, view: String, title: String, disabled: String?,
                   toggle: @escaping () -> Void) -> some View {
    let help = disabled ?? "\(shown ? "Hide" : "Show") \(title) \(view)"
    return Button(action: toggle) {
      Image(systemName: shown ? "eye" : "eye.slash")
        .foregroundStyle(shown ? Color.accentColor : P.secondaryInk)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(AIMIconButtonStyle())
    .focusEffectDisabled()
    .disabled(disabled != nil)
    .opacity(disabled != nil ? 0.5 : 1)
    .help(help)
    .accessibilityLabel("\(title) \(view)")
    .accessibilityValue(shown ? "Shown" : "Hidden")
    .frame(width: Self.eyeWidth)
  }
}

/// Each bar's two eyes as the popover applies them (pure, for the dialog and the checks).
enum MenuBarBarsState {
  struct Row: Equatable { let title: String; let glance: Bool; let expanded: Bool }

  static func rows(_ accounts: [MenuBarAccountSnapshot], _ choices: MenuBarBarChoices) -> [Row] {
    let firstTwo = Set(accounts.flatMap { account -> [String] in
      var plain = account
      plain.barChoices = MenuBarBarChoices()
      return MenuBarPresentation.lines(for: plain).compactMap(\.key)
    })
    return MenuBarPresentation.barTitles(accounts).map { title in
      let glance = choices.glance[title] ?? firstTwo.contains(title)
      return Row(title: title, glance: glance, expanded: glance || choices.expanded[title] ?? true)
    }
  }
}
