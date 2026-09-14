import AIManagerCore
import AppKit
import SwiftUI

@MainActor final class AIManagerWindow: NSWindow {
  static let fixedSize = NSSize(width: 1120, height: 740)
  static let frameAutosaveName = "AIManagerMainWindow"
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

enum AIManagerWindowBehavior {
  static let minimizeToTrayKey = "minimizeToTray"

  static func hidesOnMinimize(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: minimizeToTrayKey)
  }

  @MainActor static func minimize(_ window: NSWindow?, defaults: UserDefaults = .standard) {
    guard let window else { return }
    if hidesOnMinimize(defaults: defaults) {
      window.orderOut(nil)
    } else {
      window.miniaturize(nil)
    }
  }
}

@MainActor
final class AIManagerWindowController<Content: View>: NSWindowController, NSWindowDelegate {
  private let placementDefaults: UserDefaults
  private var preserveUnavailableDisplayPlacement = false
  private var unavailableDisplayFallbackFrame: NSRect?

  init(title: String, rootView: Content, placementDefaults: UserDefaults = .standard) {
    self.placementDefaults = placementDefaults
    let fixedSize = AIManagerWindow.fixedSize
    let window = AIManagerWindow(
      contentRect: NSRect(origin: .zero, size: fixedSize),
      styleMask: [.closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = title
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.collectionBehavior = [.fullScreenNone]
    let host = NSHostingView(
      rootView: rootView.frame(width: fixedSize.width, height: fixedSize.height))
    host.frame = NSRect(origin: .zero, size: fixedSize)
    host.focusRingType = .none
    window.contentView = host
    window.contentMinSize = fixedSize
    window.contentMaxSize = fixedSize
    window.minSize = fixedSize
    window.maxSize = fixedSize
    window.isReleasedWhenClosed = false
    window.setContentSize(fixedSize)
    let restoreOutcome = AIManagerWindowPlacement.restore(
      window, autosaveName: AIManagerWindow.frameAutosaveName, defaults: placementDefaults)
    if restoreOutcome != .restored { window.center() }
    super.init(window: window)
    preserveUnavailableDisplayPlacement = restoreOutcome == .savedDisplayUnavailable
    unavailableDisplayFallbackFrame = preserveUnavailableDisplayPlacement ? window.frame : nil
    window.delegate = self
  }
  @available(*, unavailable) required init?(coder: NSCoder) { nil }

  func windowDidMove(_ notification: Notification) {
    if preserveUnavailableDisplayPlacement,
      let fallback = unavailableDisplayFallbackFrame,
      framesMatch(window?.frame, fallback)
    {
      return
    }
    preserveUnavailableDisplayPlacement = false
    unavailableDisplayFallbackFrame = nil
    savePlacement()
  }

  func windowWillClose(_ notification: Notification) { savePlacement() }

  func savePlacement() {
    guard !preserveUnavailableDisplayPlacement, let window else { return }
    AIManagerWindowPlacement.save(window, defaults: placementDefaults)
  }

  private func framesMatch(_ left: NSRect?, _ right: NSRect) -> Bool {
    guard let left else { return false }
    return abs(left.minX - right.minX) < 1 && abs(left.minY - right.minY) < 1
      && abs(left.width - right.width) < 1 && abs(left.height - right.height) < 1
  }

  func present() {
    guard let window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    showWindow(nil)
    window.makeKeyAndOrderFront(nil)
  }
}

private final class WindowTarget: ObservableObject { weak var window: NSWindow? }
private final class WindowResolver: NSView {
  var resolve: ((NSWindow) -> Void)?
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window { resolve?(window) }
  }
}
private struct WindowReader: NSViewRepresentable {
  let resolve: (NSWindow) -> Void
  func makeNSView(context: Context) -> WindowResolver {
    let view = WindowResolver()
    view.resolve = resolve
    return view
  }
  func updateNSView(_ view: WindowResolver, context: Context) {
    view.resolve = resolve
    if let window = view.window { resolve(window) }
  }
}
final class AIMTitleDragView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 1 { window?.performDrag(with: event) }
  }
}
private struct WindowDragRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { AIMTitleDragView() }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

private extension AIManagerPage {
  var icon: AIMIcon.Name {
    switch self {
    case .accounts: .account
    case .backup: .backup
    case .history: .history
    case .settings: .settings
    }
  }
  var railIconSize: CGFloat {
    self == .history ? AIMTheme.historyRailIconSize : AIMTheme.railIconSize
  }
  var subtitle: String {
    switch self {
    case .accounts: "Import, verify, and switch accounts"
    case .backup: "Snapshots and interrupted operations"
    case .history: "The merged resume library"
    case .settings: "One configuration across every account"
    }
  }
}

struct AccountWindow: View {
  @ObservedObject var model: AccountViewModel
  @StateObject private var target = WindowTarget()
  @State private var page: AIManagerPage = .accounts
  @AppStorage("appearanceMode") private var appearanceMode = "system"
  @AppStorage("keyboardFocusIndicators") private var showFocusIndicators = false
  @State private var refreshHovered = false
  @Environment(\.colorScheme) private var systemScheme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  private var themeOverride: ColorScheme? {
    appearanceMode == "dark" ? .dark : (appearanceMode == "light" ? .light : nil)
  }
  private var dark: Bool { (themeOverride ?? systemScheme) == .dark }

  init(model: AccountViewModel, initialPageIndex: Int = 0) {
    self.model = model
    let pages = AIManagerPage.allCases
    _page = State(initialValue: pages.indices.contains(initialPageIndex) ? pages[initialPageIndex] : .accounts)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        HStack(spacing: 0) {
          rail.zIndex(10)
          VStack(spacing: 0) {
            topbar
            Group {
              if let error = model.errorMessage, !model.showImport {
                ErrorBar(message: error, copy: { model.copyWarnings([error]) }) {
                  model.errorMessage = nil
                }
                  .padding(.horizontal, 12).padding(.top, 12)
                  .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -3)))
              }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.errorMessage)
            Group {
              switch page {
              case .accounts: AccountsPage(model: model)
              case .backup: BackupPage(model: model)
              case .history: HistoryPage(model: model)
              case .settings:
                SharedSettingsPage(model: model, showFocusIndicators: $showFocusIndicators)
              }
            }
            .id(page)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 3)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .disabled(model.showImport)
        .accessibilityHidden(model.showImport)

        RailTop(
          close: { target.window?.close() },
          minimize: { AIManagerWindowBehavior.minimize(target.window) }
        )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .allowsHitTesting(!model.showImport)
          .accessibilityHidden(model.showImport)
          .zIndex(20)

        if model.showImport {
          Group {
            if reduceTransparency {
              AIMTheme.canvas.opacity(0.94)
            } else {
              AIMVisualEffect(material: .hudWindow, blendingMode: .withinWindow, darkMode: dark)
                .overlay(AIMTheme.canvas.opacity(0.62))
            }
          }
          .ignoresSafeArea()
          Group {
            switch model.accountModalMode {
            case .add:
              AddAccountFlow(model: model)
            case .advancedImport:
              ImportFlow(model: model)
            }
          }
            .frame(
              width: min(780, geometry.size.width - 48),
              height: min(AIMTheme.modalHeight, geometry.size.height - 48)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(dark ? 0.22 : 0.1), radius: 34, y: 14)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4)))
            .accessibilityElement(children: .contain)
        }
      }
    }
    .font(AIMTheme.sans(13)).foregroundStyle(AIMTheme.ink)
    .background {
      if reduceTransparency {
        AIMTheme.canvas
      } else {
        AIMVisualEffect(material: .underWindowBackground, blendingMode: .behindWindow, darkMode: dark)
        AIMTheme.canvas.opacity(dark ? 0.88 : 0.91)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.navigation), value: page)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.modal), value: model.showImport)
    .environment(\.aimDarkMode, dark)
    .environment(\.aimFocusIndicatorsEnabled, showFocusIndicators)
    .focusEffectDisabled(!showFocusIndicators)
    .preferredColorScheme(themeOverride)
    .background(
      WindowReader { window in
        target.window = window
        applyAppearance(to: window)
        applyFocusPolicy(to: window)
        AIManagerBrand.installApplicationIcon(dark: dark)
      }
    ).ignoresSafeArea(.container, edges: .top)
    .onChange(of: dark) { _, _ in
      if let window = target.window { applyAppearance(to: window) }
      AIManagerBrand.installApplicationIcon(dark: dark)
    }
    .onChange(of: showFocusIndicators) { _, _ in
      if let window = target.window { applyFocusPolicy(to: window) }
    }
    .onReceive(NotificationCenter.default.publisher(for: AIManagerNavigation.request)) { notification in
      guard let requestedPage = notification.object as? AIManagerPage else { return }
      page = requestedPage
      NotificationCenter.default.post(name: AIManagerNavigation.didShowPage, object: requestedPage)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.reloadAfterActivation() } }
    }
  }

  private func applyAppearance(to window: NSWindow) {
    guard appearanceMode != "system" else {
      if window.appearance != nil { window.appearance = nil }
      return
    }
    let name: NSAppearance.Name = dark ? .darkAqua : .aqua
    if window.appearance?.name != name { window.appearance = NSAppearance(named: name) }
  }

  private func applyFocusPolicy(to window: NSWindow) {
    window.contentView?.focusRingType = showFocusIndicators ? .default : .none
  }

  private var rail: some View {
    VStack(spacing: 0) {
      Color.clear.frame(width: AIMTheme.railWidth, height: AIMTheme.railWidth)
        .accessibilityHidden(true)
      ForEach(AIManagerPage.allCases, id: \.self) { item in
        RailButton(
          icon: item.icon, label: item.rawValue, active: page == item,
          iconSize: item.railIconSize
        ) { page = item }
      }
      Spacer()
      RailButton(icon: dark ? .sun : .moon, label: dark ? "Light mode" : "Dark mode", active: false)
      {
        withAnimation(reduceMotion ? nil : .easeOut(duration: AIMMotion.theme)) {
          appearanceMode = dark ? "light" : "dark"
        }
      }
      RailButton(icon: .plus, label: "Add account", active: false, disabled: model.isBusy) {
        Task { await model.beginAddAccount() }
      }
    }.frame(width: AIMTheme.railWidth).background(AIMTheme.rail.opacity(reduceTransparency ? 1 : 0.96))
      .overlay(alignment: .trailing) {
      Rectangle().fill(AIMTheme.railLine).frame(width: 1)
    }
  }
  private var topbar: some View {
    ZStack {
      WindowDragRegion()
      HStack(alignment: .lastTextBaseline, spacing: 14) {
        Text(page.rawValue).font(AIMTheme.sans(22, weight: .semibold)).tracking(-0.55).lineLimit(1)
        Text(page.subtitle).font(AIMTheme.sans(13)).foregroundStyle(AIMTheme.muted).lineLimit(1)
        Spacer(minLength: 12)
      }
      .allowsHitTesting(false)
      Button {
        Task { await model.refresh() }
      } label: {
        AIMIcon(name: .refresh, size: 15)
          .foregroundStyle(refreshHovered && !model.isBusy ? AIMTheme.ink : AIMTheme.muted)
          .frame(width: 32, height: 32).contentShape(Rectangle())
      }
      .buttonStyle(AIMPressButtonStyle())
      .disabled(model.isBusy)
      .opacity(model.isBusy ? 0.42 : 1)
      .onHover { refreshHovered = $0 && !model.isBusy }
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: refreshHovered)
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.isBusy)
      .help(refreshHelp)
      .accessibilityLabel(refreshAccessibilityLabel)
      .accessibilityHint(refreshHelp)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
      .padding(.horizontal, AIMTheme.modalOuterInset)
      .frame(height: AIMTheme.topbarHeight)
      .background(AIMTheme.canvas.opacity(reduceTransparency ? 1 : 0.92))
      .overlay(alignment: .bottom) { Rectangle().fill(AIMTheme.railLine).frame(height: 1) }
  }

  private var refreshHelp: String {
    guard let refreshedAt = model.refreshedAt else {
      return refreshAccessibilityLabel
    }
    return "Last refreshed \(refreshedAt.formatted(date: .omitted, time: .shortened))"
  }

  private var refreshAccessibilityLabel: String {
    #if AI_MANAGER_PREVIEW
    return model.isDemo ? "Refresh preview data" : "Refresh accounts"
    #else
    return "Refresh accounts"
    #endif
  }
}

private struct RailTop: View {
  let close: () -> Void, minimize: () -> Void
  @State private var hover = false
  @State private var closeHover = false
  @State private var minimizeHover = false
  @State private var pendingHide: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var showMinimize: Bool { hover }
  var body: some View {
    ZStack(alignment: .topLeading) {
      Button(action: minimize) {
        AIMIcon(name: .minimize, size: 15).foregroundStyle(
          minimizeHover ? AIMTheme.ink : AIMTheme.muted
        )
        .frame(width: AIMTheme.windowControlSize, height: AIMTheme.windowControlSize)
        .background(minimizeHover ? AIMTheme.minimizeHover : AIMTheme.minimizeControl)
        .contentShape(Rectangle())
      }.buttonStyle(AIMPressButtonStyle()).focusable()
        .accessibilityLabel("Minimize window")
        .accessibilityHidden(!showMinimize)
        .offset(x: showMinimize ? AIMTheme.windowControlSize : 0)
        .opacity(showMinimize ? 1 : 0)
        .allowsHitTesting(showMinimize)
        .onHover { value in
          minimizeHover = value
          updateHover(value)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.minimize), value: showMinimize)
        .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: minimizeHover)
      Button(action: close) {
        AIMIcon(name: .close, size: 15).foregroundStyle(Color(nsColor: .systemRed))
          .frame(width: AIMTheme.windowControlSize, height: AIMTheme.windowControlSize)
          .background(alignment: .leading) {
            ZStack {
              AIMTheme.rail
              Color(nsColor: .systemRed).opacity(closeHover ? 0.12 : 0)
                .animation(
                  reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: closeHover)
            }.frame(
              width: AIMTheme.windowControlSize - 1,
              height: AIMTheme.windowControlSize)
          }
          .contentShape(Rectangle())
      }.buttonStyle(AIMPressButtonStyle()).focusable()
        .accessibilityLabel("Close window")
        .onHover { value in
          closeHover = value
          updateHover(value)
        }
        .zIndex(1)
    }
    .frame(
      width: AIMTheme.windowControlSize * 2,
      height: AIMTheme.windowControlSize,
      alignment: .topLeading
    )
  }

  private func updateHover(_ value: Bool) {
    pendingHide?.cancel()
    if value {
      hover = true
    } else {
      pendingHide = Task {
        try? await Task.sleep(for: .milliseconds(70))
        guard !Task.isCancelled else { return }
        hover = false
      }
    }
  }
}

private struct RailButton: View {
  let icon: AIMIcon.Name, label: String, active: Bool
  var disabled = false
  var iconSize = AIMTheme.railIconSize
  let action: () -> Void
  @State private var hover = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  private var unavailable: Bool { disabled || !isEnabled }
  var body: some View {
    Button(action: action) {
      AIMIcon(name: icon, size: iconSize).frame(width: 48, height: 48).foregroundStyle(
        active ? AIMTheme.activeInk : (hover && !unavailable ? AIMTheme.ink : AIMTheme.railIdle)
      ).background(active ? AIMTheme.active : (hover && !unavailable ? AIMTheme.panel2 : .clear))
        .contentShape(Rectangle())
    }.buttonStyle(AIMPressButtonStyle()).disabled(disabled).help(label).accessibilityLabel(label).accessibilityAddTraits(
      active ? .isSelected : []
    ).onHover { hover = $0 && !unavailable }.animation(
      reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: hover)
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: active)
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: unavailable)
  }
}
private enum ButtonTone { case normal, primary, danger }
private struct AIMButton: View {
  let title: String
  var icon: AIMIcon.Name?
  var tone: ButtonTone = .normal
  var disabled = false
  let action: () -> Void
  @State private var hover = false
  @FocusState private var focused: Bool
  @Environment(\.aimFocusIndicatorsEnabled) private var focusIndicatorsEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  private var unavailable: Bool { disabled || !isEnabled }
  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let icon { AIMIcon(name: icon, size: 13) }
        Text(title).lineLimit(1)
      }.font(AIMTheme.sans(12, weight: .medium)).padding(.horizontal, 13).frame(height: 30)
        .foregroundStyle(
          unavailable
            ? AIMTheme.disabledInk
            : (tone == .primary
              ? AIMTheme.canvas : (tone == .danger ? AIMTheme.statusInk : AIMTheme.ink))
        ).background(
          unavailable
            ? AIMTheme.disabledControl
            : (tone == .primary
              ? (hover ? AIMTheme.primaryHover : AIMTheme.ink)
              : (tone == .danger
                ? AIMTheme.red
                : (hover ? AIMTheme.controlHover : AIMTheme.control)))
        ).overlay {
          if tone == .danger && hover {
            RoundedRectangle(cornerRadius: 3).fill(AIMTheme.statusInk.opacity(0.08))
          }
          if focused, focusIndicatorsEnabled {
            RoundedRectangle(cornerRadius: 3).stroke(AIMTheme.blue, lineWidth: 2)
          }
        }.clipShape(RoundedRectangle(cornerRadius: 3))
    }
    .buttonStyle(AIMPressButtonStyle()).focused($focused).disabled(disabled).onHover {
      hover = $0 && !unavailable
    }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: hover)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: unavailable)
  }
}
private struct AIMIconButton: View {
  let icon: AIMIcon.Name
  let label: String
  var tone: ButtonTone = .normal
  var disabled = false
  let action: () -> Void
  @State private var hover = false
  @FocusState private var focused: Bool
  @Environment(\.aimFocusIndicatorsEnabled) private var focusIndicatorsEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  private var unavailable: Bool { disabled || !isEnabled }

  var body: some View {
    Button(action: action) {
      AIMIcon(name: icon, size: 13)
        .frame(width: 30, height: 30)
        .foregroundStyle(
          unavailable
            ? AIMTheme.disabledInk
            : (tone == .danger ? AIMTheme.statusInk : AIMTheme.ink)
        )
        .background(
          unavailable
            ? AIMTheme.disabledControl
            : (tone == .danger
              ? AIMTheme.red
              : (hover ? AIMTheme.controlHover : AIMTheme.control))
        )
        .overlay {
          if focused, focusIndicatorsEnabled {
            RoundedRectangle(cornerRadius: 3).stroke(AIMTheme.blue, lineWidth: 2)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
    .focused($focused)
    .disabled(disabled)
    .onHover { hover = $0 && !unavailable }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: hover)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: unavailable)
    .help(label)
    .accessibilityLabel(label)
  }
}
private struct Badge: View {
  let text: String, color: Color
  var ink: Color = AIMTheme.statusInk
  var body: some View {
    Text(text.uppercased()).font(AIMTheme.sans(10, weight: .semibold)).padding(.horizontal, 6)
      .frame(height: 18).foregroundStyle(ink).background(color).clipShape(
        RoundedRectangle(cornerRadius: 3))
  }
}

enum AccountActionCopy {
  static let use = "Use for new Codex sessions"
  static let open = "Open Codex"
  static let useAndOpen = "Use & Open Codex"
  static let check = "Check account files"
  static let copyAuthPath = "Copy auth path"
  static let delete = "Delete account"
}

private struct PendingAccountDeletion: Identifiable {
  let account: AccountRecord
  var id: UUID { account.id }
}

private struct AccountsPage: View {
  @ObservedObject var model: AccountViewModel
  @State private var importHovered = false
  @State private var pendingDeletion: PendingAccountDeletion?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    HStack(spacing: 8) {
      AIMPanel(title: "Accounts") {
        VStack(spacing: 0) {
          AIMScrollView {
            LazyVStack(spacing: 0) {
              ForEach(model.status?.accounts ?? []) { account in
                Button {
                  model.selectedAccountID = account.id
                } label: {
                  AccountListRow(
                    account: account, selected: account.id == model.selectedAccountID,
                    isDefault: account.id == model.status?.defaultAccountID)
                }
                .buttonStyle(AIMPressButtonStyle())
                .contextMenu {
                  accountContextMenu(for: account)
                }
              }
              if !model.hasLoaded {
                HStack(spacing: 8) {
                  ProgressView().controlSize(.small)
                  Text("Loading accounts…")
                }.font(AIMTheme.sans(12)).foregroundStyle(AIMTheme.muted)
                  .padding(16).frame(maxWidth: .infinity, alignment: .leading)
              } else if model.status?.accounts.isEmpty != false {
                Text("No accounts yet.").font(AIMTheme.sans(12)).foregroundStyle(AIMTheme.muted)
                  .padding(16).frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          Button {
            Task { await model.beginAddAccount() }
          } label: {
            HStack {
              AIMIcon(name: .plus, size: 13)
              Text("Add account")
              Spacer()
            }.font(AIMTheme.sans(12, weight: .medium)).padding(.horizontal, 12).frame(height: 40)
              .foregroundStyle(model.isBusy || !model.hasLoaded ? AIMTheme.disabledInk : AIMTheme.ink)
              .background(importHovered && !model.isBusy && model.hasLoaded ? AIMTheme.controlHover : AIMTheme.panel2)
          }.buttonStyle(AIMPressButtonStyle()).keyboardShortcut("i", modifiers: [.command])
            .disabled(model.isBusy || !model.hasLoaded)
            .onHover { importHovered = $0 && !model.isBusy && model.hasLoaded }
            .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: importHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.isBusy)
        }
      }.frame(width: AIMTheme.listWidth)
      if let account = model.selectedAccount {
        AccountDetail(account: account, model: model) {
          prepareDeletion(of: account)
        }
      } else {
        EmptyAccountView(model: model)
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset).padding(.top, 12).padding(.bottom, 24)
    .alert(item: $pendingDeletion) { deletion in
      let accountName = deletion.account.identity.heroName
      return Alert(
        title: Text("Delete \(accountName)?"),
        message: Text("Switch will remove \(accountName)'s saved auth.json. The original source stays unchanged."),
        primaryButton: .destructive(Text("Delete account")) {
          Task { await model.deleteAccount(deletion.account.id) }
        },
        secondaryButton: .cancel())
    }
  }

  @ViewBuilder
  private func accountContextMenu(for account: AccountRecord) -> some View {
    let isDefault = account.id == model.status?.defaultAccountID
    Button(AccountActionCopy.use) {
      Task { await model.switchDefault(to: account.id) }
    }
    .disabled(model.isBusy || isDefault)
    Button(isDefault ? AccountActionCopy.open : AccountActionCopy.useAndOpen) {
      Task { await model.openAccount(account.id) }
    }
    .disabled(model.isBusy)
    Button(AccountActionCopy.check) {
      Task { await model.checkAccount(account.id) }
    }
    .disabled(model.isBusy)
    Button(AccountActionCopy.copyAuthPath) {
      model.copySavedAuthPath(for: account.id)
    }
    Divider()
    Button(deleteActionLabel(for: account), role: .destructive) {
      prepareDeletion(of: account)
    }
    .disabled(model.isBusy || !model.canDeleteAccount(account.id))
  }

  private func prepareDeletion(of account: AccountRecord) {
    guard model.canDeleteAccount(account.id) else {
      model.errorMessage = "Use another account for new Codex sessions before deleting the default account."
      return
    }
    pendingDeletion = PendingAccountDeletion(account: account)
  }

  private func deleteActionLabel(for account: AccountRecord) -> String {
    account.id == model.status?.defaultAccountID
      ? "Use another account before deleting the default account"
      : AccountActionCopy.delete
  }
}
private struct AccountListRow: View {
  let account: AccountRecord, selected: Bool, isDefault: Bool
  @State private var hover = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        Text(account.identity.heroName).font(AIMTheme.sans(12, weight: .medium)).lineLimit(1)
        Spacer()
        if isDefault { AIMIcon(name: .check, size: 11) }
      }
      Text(account.identity.workspaceID ?? account.verification.state.label).font(AIMTheme.mono(10))
        .foregroundStyle(selected ? AIMTheme.activeInk.opacity(0.75) : AIMTheme.muted).lineLimit(1)
    }.padding(.horizontal, 12).padding(.vertical, 6).frame(
      maxWidth: .infinity, minHeight: 44, alignment: .leading
    ).foregroundStyle(selected ? AIMTheme.activeInk : AIMTheme.ink).background(
      selected ? AIMTheme.active : (hover ? AIMTheme.panel2 : .clear)
    ).overlay(alignment: .bottom) { Rectangle().fill(AIMTheme.lineSoft).frame(height: 1) }
      .contentShape(Rectangle()).onHover { hover = $0 }.accessibilityElement(children: .combine)
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityValue(isDefault ? "Default account" : "Not the default account")
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: hover)
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: selected)
  }
}
private struct EmptyAccountView: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    AIMPanel(title: "Account") {
      Group {
        if !model.hasLoaded {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading Codex accounts…").font(AIMTheme.sans(13, weight: .medium))
          }
        } else {
          VStack(alignment: .leading, spacing: 10) {
            Text("Add your first account").font(AIMTheme.sans(18, weight: .semibold))
            Text(
              "Switch found no saved account. Sign in to Codex or use Advanced Import for an existing folder."
            ).foregroundStyle(AIMTheme.muted).frame(maxWidth: 520, alignment: .leading)
            HStack(spacing: 6) {
              AIMButton(title: "Add account", icon: .plus, tone: .primary, disabled: model.isBusy) {
                Task { await model.beginAddAccount() }
              }
              AIMButton(title: "Advanced Import…", icon: .folder, disabled: model.isBusy) {
                Task { await model.beginAdvancedImport() }
              }
            }
          }
        }
      }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }.frame(maxWidth: .infinity)
  }
}

private struct AccountDetail: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
  let delete: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var issues: [LinkedSettingsDivergence] {
    model.status?.linkedSettingsDivergences.filter { $0.accountID == account.id } ?? []
  }
  var body: some View {
    AIMScrollView {
      VStack(spacing: 8) {
        AIMPanel(title: "Identity") {
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text(account.identity.heroName).font(AIMTheme.sans(22, weight: .semibold))
                  .lineLimit(1).textSelection(.enabled)
                Text(account.identity.workspaceID ?? "Personal workspace").font(AIMTheme.mono(10))
                  .foregroundStyle(AIMTheme.muted).textSelection(.enabled)
              }
              Spacer()
              if account.id == model.status?.defaultAccountID {
                Badge(text: "Default", color: AIMTheme.green)
              }
              Badge(text: account.verification.state.label, color: account.verification.state.color)
            }
            Text(account.verification.detail).font(AIMTheme.sans(11)).foregroundStyle(
              AIMTheme.muted
            ).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 4) { actions }
              VStack(alignment: .leading, spacing: 4) { actions }
            }
          }.padding(16)
        }
        AccountUsagePanel(account: account, model: model)
        AIMPanel(title: "Account details") {
          VStack(spacing: 0) {
            DetailRow(label: "Saved auth", value: account.credentialFile.path)
            DetailRow(label: "Source", value: account.source.path, zebra: true)
            DetailRow(label: "Shared settings", value: model.paths.sharedRoot.path)
            DetailRow(
              label: "Imported",
              value: account.importedAt.formatted(date: .abbreviated, time: .shortened), zebra: true
            )
            DetailRow(
              label: "Last used",
              value: account.lastUsedAt?.formatted(date: .abbreviated, time: .shortened)
                ?? "Not launched yet")
          }
        }
        if !issues.isEmpty {
          AIMPanel(title: "Shared settings need repair") {
            VStack(spacing: 0) {
              ForEach(issues) { issue in
                HStack(spacing: 12) {
                  AIMIcon(name: .warning, size: 15).foregroundStyle(AIMTheme.amber)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(issue.relativePath).font(AIMTheme.mono(11, weight: .semibold))
                    Text(issue.localPath.path).font(AIMTheme.mono(9)).foregroundStyle(
                      AIMTheme.muted
                    ).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                      .help(issue.localPath.path)
                  }
                  Spacer()
                  WarningCopyButton(label: "Copy repair warning") {
                    model.copyWarnings([
                      "Shared setting needs repair: \(issue.relativePath)\nLocation: \(issue.localPath.path)"
                    ])
                  }
                  AIMButton(title: "Back up and repair", tone: .danger, disabled: model.isBusy) {
                    Task { await model.repairLinkedSetting(issue) }
                  }
                }.padding(12).overlay(alignment: .bottom) {
                  Rectangle().fill(AIMTheme.lineSoft).frame(height: 1)
                }
              }
            }
          }
        }
        Group {
          if let notice = model.notice {
            Notice(text: notice, tone: AIMTheme.blue)
              .transition(reduceMotion ? .identity : .opacity)
          }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.notice)
      }.frame(maxWidth: .infinity)
    }.frame(maxWidth: .infinity)
  }
  @ViewBuilder private var actions: some View {
    AIMButton(
      title: AccountActionCopy.use, tone: .primary,
      disabled: model.isBusy
    ) { Task { await model.switchDefault() } }
    AIMButton(
      title: account.id == model.status?.defaultAccountID
        ? AccountActionCopy.open : AccountActionCopy.useAndOpen,
      icon: .play,
      disabled: model.isBusy
    ) {
      Task { await model.openAccount(account.id) }
    }
    AIMButton(title: AccountActionCopy.check, icon: .check, disabled: model.isBusy) {
      Task { await model.checkAccount(account.id) }
    }
    AIMButton(title: AccountActionCopy.copyAuthPath, icon: .copy) {
      model.copySavedAuthPath(for: account.id)
    }
    AIMIconButton(
      icon: .trash,
      label: account.id == model.status?.defaultAccountID
        ? "Use another account before deleting the default account"
        : AccountActionCopy.delete,
      tone: .danger,
      disabled: model.isBusy || !model.canDeleteAccount(account.id),
      action: delete)
  }
}

private struct AccountUsagePanel: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel

  private var snapshot: CodexAccountUsageSnapshot? { model.usage(for: account.id) }
  private var cached: CachedCodexAccountUsage? { model.cachedUsage(for: account.id) }
  private var isActive: Bool { account.id == model.status?.defaultAccountID }
  private var isRefreshing: Bool { model.usageRefreshAccountID == account.id }
  private var usageFailure: String? {
    model.usageError(for: account.id) ?? cached?.failureMessage
  }

  private var limitBuckets: [(key: String, value: CodexRateLimitBucketSnapshot)] {
    guard let limits = snapshot?.rateLimits else { return [] }
    var result: [(String, CodexRateLimitBucketSnapshot)] = []
    var seen = Set<String>()
    if let bucket = limits.defaultBucket {
      let key = bucket.id ?? "default"
      seen.insert(key)
      result.append((key, bucket))
    }
    for (key, bucket) in limits.buckets.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
      let identity = bucket.id ?? key
      guard seen.insert(identity).inserted else { continue }
      result.append((key, bucket))
    }
    return result
  }

  var body: some View {
    AIMPanel(title: "Usage") {
      VStack(spacing: 0) {
        if let snapshot {
          VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
              Text(snapshot.account?.plan?.capitalized ?? "Codex usage")
                .font(AIMTheme.sans(13, weight: .semibold))
              Spacer()
              usageStatus
            }
            .padding(.bottom, 14)

            HStack(spacing: 18) {
              UsageFact(
                label: "Ordinary usage",
                value: formatAvailability(snapshot.rateLimits?.ordinaryUsageAllowed)
              )
              UsageFact(
                label: "Authentication",
                value: authenticationCopy(snapshot)
              )
              Spacer()
            }
            .padding(.bottom, 14)

            ForEach(Array(limitBuckets.enumerated()), id: \.element.key) { index, item in
              UsageBucket(
                bucket: item.value,
                fallbackName: item.key,
                windowLabel: windowLabel
              )
              .padding(.vertical, 12)
              .padding(.horizontal, 12)
              .background(index.isMultiple(of: 2) ? AIMTheme.panel2 : AIMTheme.listStripe)
            }

            if limitBuckets.isEmpty {
              UsageUnavailableRow(text: "Rate limits unavailable")
            }

            HStack(spacing: 20) {
              UsageFact(label: "Lifetime", value: formatTokens(snapshot.usage?.lifetimeTokens))
              UsageFact(label: "Peak day", value: formatTokens(snapshot.usage?.peakDailyTokens))
              UsageFact(
                label: "Current streak",
                value: formatDays(snapshot.usage?.currentStreakDays)
              )
              UsageFact(
                label: "Longest streak",
                value: formatDays(snapshot.usage?.longestStreakDays)
              )
              UsageFact(
                label: "Longest turn",
                value: formatDuration(snapshot.usage?.longestRunningTurnSeconds)
              )
              Spacer()
            }
            .padding(.top, 14)

            if !snapshot.dailyUsage.isEmpty {
              VStack(spacing: 0) {
                HStack {
                  Text("Daily activity").font(AIMTheme.sans(11, weight: .semibold))
                  Spacer()
                  Text("Tokens").font(AIMTheme.sans(9, weight: .medium))
                    .foregroundStyle(AIMTheme.muted)
                }
                .padding(.horizontal, 12).frame(height: 32)
                ForEach(Array(snapshot.dailyUsage.enumerated()), id: \.offset) { index, day in
                  HStack(spacing: 12) {
                    Text(day.startDate ?? "Date unavailable")
                      .font(AIMTheme.mono(10)).foregroundStyle(AIMTheme.muted)
                    Spacer()
                    Text(formatTokens(day.tokens))
                      .font(AIMTheme.mono(10, weight: .semibold))
                  }
                  .padding(.horizontal, 12).frame(height: 30)
                  .background(index.isMultiple(of: 2) ? AIMTheme.panel : AIMTheme.listStripe)
                }
              }
              .padding(.top, 14)
            } else {
              UsageUnavailableRow(text: "Daily activity unavailable")
                .padding(.top, 10)
            }
          }
          .padding(16)
        } else {
          HStack(spacing: 12) {
            AIMIcon(name: .info, size: 15).foregroundStyle(AIMTheme.muted)
            VStack(alignment: .leading, spacing: 3) {
              Text(isActive ? "Usage has not been checked" : "No cached usage for this account")
                .font(AIMTheme.sans(12, weight: .semibold))
              Text(
                isActive
                  ? "Refresh to read the current Codex limits."
                  : "Usage is updated while an account is active."
              )
              .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
            }
            Spacer()
            if isActive { refreshButton }
          }
          .padding(16)
        }
      }
    }
  }

  @ViewBuilder private var usageStatus: some View {
    HStack(spacing: 8) {
      if let failure = usageFailure {
        Text(failure).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.amber).lineLimit(1)
          .help(failure)
        WarningCopyButton(label: "Copy usage error") {
          model.copyWarnings([failure])
        }
      } else if let fetchedAt = snapshot?.fetchedAt {
        Text(cached?.isStale == true ? "Cached" : "Updated")
          .font(AIMTheme.sans(10, weight: .medium)).foregroundStyle(AIMTheme.muted)
        Text(fetchedAt.formatted(date: .omitted, time: .shortened))
          .font(AIMTheme.mono(9)).foregroundStyle(AIMTheme.muted)
      }
      if isActive { refreshButton }
    }
  }

  private var refreshButton: some View {
    AIMButton(
      title: isRefreshing ? "Refreshing" : "Refresh usage",
      icon: .refresh,
      disabled: isRefreshing || model.isBusy
    ) {
      Task { await model.refreshDefaultUsage() }
    }
  }

  private func windowLabel(
    _ window: CodexRateLimitWindowSnapshot?,
    fallback: String
  ) -> String {
    guard let minutes = window?.windowDurationMinutes else { return fallback }
    if minutes >= 10_080 { return "Weekly window" }
    if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour window" }
    return "\(minutes)-minute window"
  }

  private func formatTokens(_ value: Int64?) -> String {
    guard let value else { return "Unavailable" }
    return value.formatted(.number.notation(.compactName))
  }

  private func formatDays(_ value: Int64?) -> String {
    guard let value else { return "Unavailable" }
    return "\(value) day\(value == 1 ? "" : "s")"
  }

  private func formatDuration(_ seconds: Int64?) -> String {
    guard let seconds else { return "Unavailable" }
    return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
  }

  private func formatAvailability(_ value: Bool?) -> String {
    guard let value else { return "Unavailable" }
    return value ? "Available" : "Restricted"
  }

  private func authenticationCopy(_ snapshot: CodexAccountUsageSnapshot) -> String {
    if snapshot.account != nil { return "Signed in" }
    guard let required = snapshot.requiresOpenAIAuthentication else { return "Unavailable" }
    return required ? "Sign-in required" : "Not required"
  }
}

private struct UsageBucket: View {
  let bucket: CodexRateLimitBucketSnapshot
  let fallbackName: String
  let windowLabel: (CodexRateLimitWindowSnapshot?, String) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(bucket.name ?? fallbackName)
          .font(AIMTheme.sans(11, weight: .semibold)).lineLimit(1)
        if let model = bucket.model, !model.isEmpty {
          Text(model).font(AIMTheme.mono(9)).foregroundStyle(AIMTheme.muted).lineLimit(1)
        }
        Spacer()
        Text(bucket.plan?.capitalized ?? "Plan unavailable")
          .font(AIMTheme.sans(9, weight: .medium)).foregroundStyle(AIMTheme.muted)
      }
      HStack(spacing: 20) {
        UsageMeter(title: windowLabel(bucket.primary, "Current window"), window: bucket.primary)
        UsageMeter(title: windowLabel(bucket.secondary, "Secondary window"), window: bucket.secondary)
      }
      HStack(spacing: 20) {
        UsageFact(label: "Credits", value: creditsCopy)
        UsageFact(label: "Spend control", value: spendControlCopy)
        Spacer()
      }
    }
  }

  private var creditsCopy: String {
    guard let credits = bucket.credits else { return "Unavailable" }
    if credits.unlimited == true { return "Unlimited" }
    if let balance = credits.balance, !balance.isEmpty { return balance }
    if let hasCredits = credits.hasCredits { return hasCredits ? "Available" : "None" }
    return "Unavailable"
  }

  private var spendControlCopy: String {
    guard let reached = bucket.spendControlReached else { return "Unavailable" }
    return reached ? "Reached" : "Available"
  }
}

private struct UsageUnavailableRow: View {
  let text: String
  var body: some View {
    HStack(spacing: 8) {
      AIMIcon(name: .info, size: 12).foregroundStyle(AIMTheme.muted)
      Text(text).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
      Spacer()
    }
    .padding(.horizontal, 12).frame(height: 34).background(AIMTheme.panel2)
  }
}

private struct UsageMeter: View {
  let title: String
  let window: CodexRateLimitWindowSnapshot?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var used: Int? { window?.usedPercent.map { min(max($0, 0), 100) } }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(AIMTheme.sans(11, weight: .medium))
        Spacer()
        Text(used.map { "\($0)% used" } ?? "Unavailable")
          .font(AIMTheme.mono(10, weight: .semibold))
      }
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Rectangle().fill(AIMTheme.control)
          if let used {
            Rectangle()
              .fill(used >= 90 ? AIMTheme.red : (used >= 70 ? AIMTheme.amber : AIMTheme.blue))
              .frame(width: geometry.size.width * CGFloat(used) / 100)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
      }
      .frame(height: 5)
      Text(resetCopy).font(AIMTheme.sans(9)).foregroundStyle(AIMTheme.muted)
    }
    .frame(maxWidth: .infinity)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: used)
  }

  private var resetCopy: String {
    guard let reset = window?.resetsAt else { return "Reset time unavailable" }
    return "Resets \(reset.formatted(.relative(presentation: .named)))"
  }
}

private struct UsageFact: View {
  let label: String
  let value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(AIMTheme.sans(9)).foregroundStyle(AIMTheme.muted)
      Text(value).font(AIMTheme.mono(11, weight: .semibold))
    }
  }
}

private struct DetailRow: View {
  let label: String, value: String
  var zebra = false
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(label).font(AIMTheme.sans(11, weight: .medium)).frame(width: 118, alignment: .leading)
      Text(value).font(AIMTheme.mono(10)).foregroundStyle(AIMTheme.muted).lineLimit(1)
        .truncationMode(.middle).textSelection(.enabled).help(value)
      Spacer()
    }.padding(.horizontal, 16).frame(minHeight: 40).background(
      zebra ? AIMTheme.panel2.opacity(0.55) : .clear)
  }
}

private struct SharedSettingsPage: View {
  @ObservedObject var model: AccountViewModel
  @Binding var showFocusIndicators: Bool
  @AppStorage(AIManagerWindowBehavior.minimizeToTrayKey) private var minimizeToTray = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let shared = [
    "config.toml", "AGENTS.md", "agents", "rules", "context", "skills", "plugins", "hooks.json",
    "sessions", "archived_sessions",
  ]
  private var visibleShared: [String] {
    #if AI_MANAGER_PREVIEW
    if model.isDemo { return shared }
    #endif
    return shared.filter {
      FileManager.default.fileExists(atPath: model.paths.sharedRoot.appending(path: $0).path)
    }
  }
  var body: some View {
    AIMScrollView {
      VStack(spacing: 8) {
        AIMPanel(title: "App behavior") {
          VStack(spacing: 0) {
            settingRow(isOn: $minimizeToTray, title: "Minimize to tray") {
              Text("Hide the window and keep Switch available from its menu-bar icon.")
            }
            settingRow(isOn: $showFocusIndicators, title: "Keyboard focus indicators", zebra: true) {
              Text("Show outlines only while keyboard controls have focus.")
            }
          }
        }
        #if AI_MANAGER_PREVIEW
        if model.isDemo {
          AIMPanel(title: "Demo states") {
            HStack(spacing: 4) {
              AIMButton(title: "Sample accounts") { model.reset(to: .demo) }
              AIMButton(title: "Empty state") { model.reset(to: .empty) }
              AIMButton(title: "Issues and backups") { model.reset(to: .allStates) }
              AIMButton(title: "Refresh demo data", icon: .refresh, disabled: model.isBusy) {
                Task { await model.refresh() }
              }
              Spacer()
              AIMButton(title: "Show demo error", tone: .danger) { model.showDemoError() }
            }.padding(12)
          }
        }
        #endif
        AIMPanel(title: "Shared root") {
          VStack(spacing: 0) {
            DetailRow(label: "Location", value: model.paths.sharedRoot.path)
            HStack {
              Text("Every managed account uses this configuration and merged chat library.").font(
                AIMTheme.sans(11)
              ).foregroundStyle(AIMTheme.muted)
              Spacer()
              AIMButton(title: "Show in Finder", icon: .folder) { model.showSharedRoot() }
            }.padding(16).background(AIMTheme.panel2.opacity(0.55))
          }
        }
        AIMPanel(title: "Linked entries") {
          VStack(spacing: 0) {
            ForEach(Array(visibleShared.enumerated()), id: \.element) { index, item in
              HStack {
                Text(item).font(AIMTheme.mono(11))
                Spacer()
                Text(item.contains("session") ? "Merged history" : "Shared").font(AIMTheme.sans(10))
                  .foregroundStyle(AIMTheme.muted)
                AIMIcon(name: .check, size: 12).foregroundStyle(AIMTheme.green)
              }.padding(.horizontal, 16).frame(height: 40).background(
                index.isMultiple(of: 2) ? .clear : AIMTheme.panel2.opacity(0.55))
            }
            if visibleShared.isEmpty {
              Text("No shared settings or history entries are present yet.")
                .font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        if let issues = model.status?.linkedSettingsDivergences, !issues.isEmpty {
          Notice(
            text:
              "\(issues.count) linked setting\(issues.count == 1 ? "" : "s") need review on the Accounts page.",
            tone: AIMTheme.amber, icon: .warning,
            copy: {
              model.copyWarnings([
                "\(issues.count) linked setting\(issues.count == 1 ? "" : "s") need review on the Accounts page."
              ])
            })
        }
        Group {
          if let notice = model.notice {
            Notice(text: notice, tone: AIMTheme.blue)
              .transition(reduceMotion ? .identity : .opacity)
          }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.notice)
      }
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.top, 12).padding(.bottom, 24)
  }

  private func settingRow<Description: View>(
    isOn: Binding<Bool>, title: String, zebra: Bool = false,
    @ViewBuilder description: () -> Description
  ) -> some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(AIMTheme.sans(11, weight: .medium))
        description().font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
      }
      Spacer(minLength: 24)
      Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        .accessibilityLabel(title)
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    .background(zebra ? AIMTheme.panel2.opacity(0.55) : .clear)
  }
}

private struct HistoryPage: View {
  @ObservedObject var model: AccountViewModel
  @State private var threadQuery = ""

  var body: some View {
    HStack(spacing: 8) {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Text("Conversations").font(AIMTheme.sans(12, weight: .semibold))
          Spacer(minLength: 4)
          Text(historyCountText)
            .font(AIMTheme.sans(9))
            .foregroundStyle(AIMTheme.muted)
            .contentTransition(.numericText())
          if model.chatHistory.skippedFileCount > 0 || model.chatHistory.unreadableRecordCount > 0 {
            WarningCopyButton(label: "Copy history warning") {
              model.copyWarnings([historyIssueText])
            }
            .help(historyIssueText)
          }
          if let error = model.chatHistoryError {
            Circle().fill(AIMTheme.red).frame(width: 6, height: 6)
              .help(error)
              .accessibilityLabel(error)
          } else if model.isChatHistoryLoading {
            ProgressView().controlSize(.small)
          }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(AIMTheme.panel2)

        HistorySearchField(text: $threadQuery, placeholder: "Search conversations")
          .padding(.horizontal, 10)
          .frame(height: 48)

        if model.isChatHistoryLoading && model.chatHistory.threads.isEmpty {
          VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading chat library").font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.chatHistory.threads.isEmpty {
          VStack(spacing: 7) {
            AIMIcon(name: .history, size: 18).foregroundStyle(AIMTheme.muted)
            Text(threadQuery.isEmpty ? "No conversations yet" : "No matching conversations")
              .font(AIMTheme.sans(11, weight: .medium))
            Text(threadQuery.isEmpty ? "New Codex chats appear here." : "Try another word or thread ID.")
              .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          AIMVirtualList(items: threadItems, rowSpacing: 0, fixedRowHeight: 50) { item in
            AnyView(ChatThreadRow(
              thread: item.thread,
              selected: item.selected,
              striped: item.striped
            ) { Task { await model.selectChat(item.id) } })
          }
        }
      }
      .frame(width: 300)
      .background(AIMTheme.panel)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))

      ChatDetailPane(model: model)
        .id(model.selectedChatID)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.top, 12)
    .padding(.bottom, 24)
    .task { await model.watchChatHistory() }
    .task(id: threadQuery) { await model.searchChatHistory(query: threadQuery) }
  }

  private var historyCountText: String {
    let result = model.chatHistory
    if threadQuery.isEmpty { return result.totalThreadCount.formatted() }
    return "\(result.matchingThreadCount.formatted()) of \(result.totalThreadCount.formatted())"
  }

  private var historyIssueText: String {
    let result = model.chatHistory
    var parts: [String] = []
    if result.skippedFileCount > 0 {
      parts.append(
        "\(result.skippedFileCount) transcript file\(result.skippedFileCount == 1 ? " was" : "s were") skipped")
    }
    if result.unreadableRecordCount > 0 {
      parts.append(
        "\(result.unreadableRecordCount) oversized or malformed record\(result.unreadableRecordCount == 1 ? " was" : "s were") skipped")
    }
    return parts.joined(separator: "; ") + "."
  }

  private var threadItems: [ChatThreadListItem] {
    model.chatHistory.threads.enumerated().map { index, thread in
      ChatThreadListItem(
        thread: thread,
        selected: model.selectedChatID == thread.id,
        striped: !index.isMultiple(of: 2))
    }
  }
}

private struct ChatThreadListItem: Identifiable, Equatable {
  let thread: ChatThreadSummary
  let selected: Bool
  let striped: Bool
  var id: String { thread.id }
}

private struct HistorySearchField: View {
  @Binding var text: String
  let placeholder: String
  @Environment(\.aimFocusIndicatorsEnabled) private var focusIndicatorsEnabled

  var body: some View {
    HStack(spacing: 8) {
      AIMIcon(name: .search, size: 11).foregroundStyle(AIMTheme.muted)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(AIMTheme.sans(10.5))
        .focusEffectDisabled(!focusIndicatorsEnabled)
      if !text.isEmpty {
        Button { text = "" } label: {
          AIMIcon(name: .close, size: 8).foregroundStyle(AIMTheme.muted)
            .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(AIMPressButtonStyle())
        .help("Clear search")
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 9)
    .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
    .background(AIMTheme.control)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }
}

private struct ChatThreadRow: View {
  let thread: ChatThreadSummary
  let selected: Bool
  let striped: Bool
  let action: () -> Void
  @State private var hovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        Text(thread.title)
          .font(AIMTheme.sans(11.5, weight: .semibold))
          .lineLimit(1)
        Text(projectLabel)
          .font(AIMTheme.sans(9.5, weight: .medium))
          .foregroundStyle(AIMTheme.muted)
          .lineLimit(1)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        selected
          ? AIMTheme.listSelection
          : (hovered
            ? AIMTheme.listHover
            : (striped ? AIMTheme.listStripe : Color.clear)))
      .overlay(alignment: .leading) {
        if selected { Rectangle().fill(AIMTheme.active).frame(width: 3) }
      }
      .foregroundStyle(AIMTheme.ink)
    }
    .buttonStyle(AIMPressButtonStyle())
    .onHover { hovered = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: hovered)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: selected)
    .accessibilityLabel("\(thread.title), \(projectLabel)")
  }

  private var projectLabel: String {
    guard let directory = thread.workingDirectory else { return "Codex" }
    let name = URL(fileURLWithPath: directory).lastPathComponent
    return name.isEmpty ? "Codex" : name
  }
}

private struct ChatDetailPane: View {
  @ObservedObject var model: AccountViewModel
  @State private var messageQuery = ""
  @State private var messageSearchResult = ChatMessageSearchResult(
    messages: [], totalMessageCount: 0, matchingMessageCount: 0)
  @State private var isSearching = false
  @State private var presentations: [String: ChatMessagePresentation] = [:]
  @State private var presentationRevision = 0

  var body: some View {
    VStack(spacing: 0) {
      if let thread = selectedSummary {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(thread.title).font(AIMTheme.sans(14, weight: .semibold)).lineLimit(1)
            Text(threadContext(thread))
              .font(AIMTheme.sans(9.5)).foregroundStyle(AIMTheme.muted).lineLimit(1)
          }
          Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(AIMTheme.panel2)
      } else {
        Color.clear.frame(height: 58).background(AIMTheme.panel2)
      }

      HStack(spacing: 10) {
        HistorySearchField(text: $messageQuery, placeholder: "Search this chat")
        if isSearching {
          ProgressView().controlSize(.small)
        } else if let detail = model.selectedChat,
                  !messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(messageCountText(detail))
            .font(AIMTheme.sans(9.5))
            .foregroundStyle(AIMTheme.muted)
            .contentTransition(.numericText())
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 46)

      if model.isChatLoading {
        VStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Opening chat").font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let detail = model.selectedChat {
        AIMVirtualList(
          items: detailItems(detail), rowSpacing: 0,
          contentRevision: presentationRevision
        ) { item in
          AnyView(detailRow(item))
        }
      } else {
        VStack(spacing: 7) {
          AIMIcon(name: .history, size: 20).foregroundStyle(AIMTheme.muted)
          Text("Select a chat").font(AIMTheme.sans(11, weight: .medium))
          Text("Messages open here without changing the transcript.")
            .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AIMTheme.panel)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
    .task(id: searchKey) { await updateMessageSearch() }
    .task(id: presentationKey) { await updatePresentations() }
  }

  private var selectedSummary: ChatThreadSummary? {
    model.selectedChat?.thread
      ?? model.chatHistory.threads.first { $0.id == model.selectedChatID }
  }

  private var searchKey: ChatMessageSearchKey {
    ChatMessageSearchKey(
      threadID: model.selectedChatID,
      query: messageQuery,
      fileByteCount: model.selectedChat?.thread.fileByteCount ?? 0)
  }

  private var presentationKey: ChatPresentationKey {
    ChatPresentationKey(
      threadID: model.selectedChatID,
      fileByteCount: model.selectedChat?.thread.fileByteCount ?? 0)
  }

  private func displayedMessages(_ detail: ChatThreadDetail) -> [ChatMessage] {
    messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? detail.messages : messageSearchResult.messages
  }

  private func detailItems(_ detail: ChatThreadDetail) -> [ChatDetailListItem] {
    var items: [ChatDetailListItem] = []
    if detail.omittedMessageCount > 0 {
      items.append(.notice(
        "\(detail.omittedMessageCount) older or oversized messages are hidden to keep this view fast."))
    }
    if !messageQuery.isEmpty && messageSearchResult.messages.isEmpty && !isSearching {
      items.append(.emptySearch)
    } else {
      let messages = displayedMessages(detail)
      items.append(contentsOf: messages.enumerated().map { index, message in
        .message(
          message,
          separated: index == 0 || messages[index - 1].role != message.role)
      })
    }
    items.append(.bottomSpace)
    return items
  }

  @ViewBuilder
  private func detailRow(_ item: ChatDetailListItem) -> some View {
    switch item {
    case let .notice(text):
      Notice(
        text: text,
        tone: AIMTheme.amber,
        icon: .warning,
        copy: { model.copyWarnings([text]) })
        .padding(.horizontal, 12)
    case let .message(message, separated):
      ChatMessageRow(
        message: message,
        presentation: presentations[message.id],
        fallbackText: model.renderedChatMessages[message.id] ?? AttributedString(message.text),
        separated: separated)
    case .emptySearch:
      VStack(spacing: 6) {
        AIMIcon(name: .search, size: 16).foregroundStyle(AIMTheme.muted)
        Text("No matching messages").font(AIMTheme.sans(10, weight: .medium))
      }
      .frame(maxWidth: .infinity, minHeight: 120)
      .padding(.horizontal, 12)
    case .bottomSpace:
      Color.clear.frame(height: 16)
    }
  }

  private func messageCountText(_ detail: ChatThreadDetail) -> String {
    if messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "\(detail.messages.count.formatted()) messages"
    }
    return "\(messageSearchResult.matchingMessageCount.formatted()) matches"
  }

  private func threadContext(_ thread: ChatThreadSummary) -> String {
    var parts: [String] = []
    if let directory = thread.workingDirectory {
      let project = URL(fileURLWithPath: directory).lastPathComponent
      if !project.isEmpty { parts.append(project) }
    }
    parts.append(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
    parts.append("\(thread.messageCount.formatted()) messages")
    if thread.archived { parts.append("Archived") }
    return parts.joined(separator: "  ·  ")
  }

  @MainActor
  private func updatePresentations() async {
    guard let detail = model.selectedChat else {
      presentations = [:]
      return
    }
    do {
      let rendered = try await ChatMessagePresenter.render(messages: detail.messages)
      guard !Task.isCancelled,
        model.selectedChatID == detail.thread.id,
        model.selectedChat?.thread.fileByteCount == detail.thread.fileByteCount
      else { return }
      presentations = rendered
      presentationRevision &+= 1
    } catch is CancellationError {
      return
    } catch {
      presentations = [:]
    }
  }

  @MainActor
  private func updateMessageSearch() async {
    guard let detail = model.selectedChat else {
      messageSearchResult = ChatMessageSearchResult(
        messages: [], totalMessageCount: 0, matchingMessageCount: 0)
      isSearching = false
      return
    }
    let terms = messageQuery
      .split(whereSeparator: \.isWhitespace)
      .map { String($0).lowercased() }
    guard !terms.isEmpty else {
      messageSearchResult = ChatMessageSearchResult(
        messages: [],
        totalMessageCount: detail.messages.count,
        matchingMessageCount: detail.messages.count)
      isSearching = false
      return
    }
    isSearching = true
    do { try await Task.sleep(for: .milliseconds(120)) }
    catch { return }
    do {
      let result = try await ChatMessageSearch.search(detail.messages, query: messageQuery)
      guard !Task.isCancelled else { return }
      messageSearchResult = result
      isSearching = false
    } catch is CancellationError {
      return
    } catch {
      messageSearchResult = ChatMessageSearchResult(
        messages: [],
        totalMessageCount: detail.messages.count,
        matchingMessageCount: 0)
      isSearching = false
    }
  }
}

private enum ChatDetailListItem: Identifiable, Equatable {
  case notice(String)
  case message(ChatMessage, separated: Bool)
  case emptySearch
  case bottomSpace

  var id: String {
    switch self {
    case let .notice(text): "notice:\(text)"
    case let .message(message, _): "message:\(message.id)"
    case .emptySearch: "empty-search"
    case .bottomSpace: "bottom-space"
    }
  }
}

private struct ChatMessageSearchKey: Hashable {
  let threadID: String?
  let query: String
  let fileByteCount: Int64
}

private struct ChatPresentationKey: Hashable {
  let threadID: String?
  let fileByteCount: Int64
}

private struct ChatMessageRow: View {
  let message: ChatMessage
  let presentation: ChatMessagePresentation?
  let fallbackText: AttributedString
  let separated: Bool
  @State private var hovered = false

  var body: some View {
    VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
      HStack(spacing: 5) {
        Text(message.role == .user ? "You" : "Codex")
          .font(AIMTheme.sans(9.5, weight: .semibold))
        if let timestamp = message.timestamp {
          Text("·")
          Text(timestamp, style: .time)
        }
        ChatCopyButton(text: message.text, label: "Copy message", emphasized: hovered)
      }
      .font(AIMTheme.sans(9.5))
      .foregroundStyle(AIMTheme.muted)

      if message.role == .user {
        ChatMessageBlocks(presentation: presentation, fallbackText: fallbackText)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .frame(maxWidth: 460, alignment: .leading)
          .background(AIMTheme.chatUserSurface)
          .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
      } else {
        HStack(alignment: .top, spacing: 12) {
          Rectangle().fill(AIMTheme.titleArt).frame(width: 2)
          ChatMessageBlocks(presentation: presentation, fallbackText: fallbackText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: 620, alignment: .leading)
      }
    }
    .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
    .padding(.horizontal, 24)
    .padding(.top, separated ? 18 : 8)
    .frame(maxWidth: .infinity, alignment: .center)
    .onHover { hovered = $0 }
  }
}

private struct ChatMessageBlocks: View {
  let presentation: ChatMessagePresentation?
  let fallbackText: AttributedString

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let presentation {
        ForEach(presentation.blocks) { block in
          ChatPresentationBlockView(block: block)
        }
        if presentation.sourceWasTruncated {
          Text("This long message is shortened in the reader.")
            .font(AIMTheme.sans(10, weight: .medium))
            .foregroundStyle(AIMTheme.amber)
        }
      } else {
        Text(fallbackText)
          .font(AIMTheme.sans(13))
          .lineSpacing(4)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ChatPresentationBlockView: View {
  let block: ChatPresentationBlock

  @ViewBuilder var body: some View {
    switch block {
    case let .paragraph(_, text):
      readable(text)
    case let .heading(_, level, text):
      Text(text)
        .font(AIMTheme.sans(level == 1 ? 17 : (level == 2 ? 15 : 13), weight: .semibold))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case let .quote(_, text):
      HStack(alignment: .top, spacing: 9) {
        Rectangle().fill(AIMTheme.line).frame(width: 2)
        readable(text).foregroundStyle(AIMTheme.muted)
      }
    case let .unorderedList(_, items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").font(AIMTheme.sans(12, weight: .semibold))
            readable(item)
          }
        }
      }
    case let .orderedList(_, items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1).")
              .font(AIMTheme.mono(10, weight: .medium))
              .frame(width: 20, alignment: .trailing)
            readable(item)
          }
        }
      }
    case let .code(_, language, preview, expanded, sourceWasTruncated):
      ChatCodeBlock(
        language: language, preview: preview, expandedText: expanded,
        sourceWasTruncated: sourceWasTruncated)
    case .divider:
      Rectangle().fill(AIMTheme.lineSoft).frame(height: 1).padding(.vertical, 2)
    }
  }

  private func readable(_ text: AttributedString) -> some View {
    Text(text)
      .font(AIMTheme.sans(13))
      .lineSpacing(4)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ChatCodeBlock: View {
  let language: String?
  let preview: String
  let expandedText: String?
  let sourceWasTruncated: Bool
  @State private var expanded = false

  private var visibleText: String { expanded ? (expandedText ?? preview) : preview }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(language?.uppercased() ?? "CODE")
          .font(AIMTheme.mono(9, weight: .semibold))
          .foregroundStyle(AIMTheme.muted)
        Spacer()
        ChatCopyButton(text: expandedText ?? preview, label: "Copy code", emphasized: true)
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(AIMTheme.panel3)

      ScrollView(.horizontal, showsIndicators: false) {
        Text(visibleText)
          .font(AIMTheme.mono(11))
          .lineSpacing(3)
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: true)
          .padding(12)
      }

      if expandedText != nil {
        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
          .buttonStyle(.plain)
          .font(AIMTheme.sans(10, weight: .medium))
          .foregroundStyle(AIMTheme.blue)
          .padding(.horizontal, 10)
          .padding(.bottom, 9)
      } else if sourceWasTruncated {
        Text("Code shortened")
          .font(AIMTheme.sans(9, weight: .medium))
          .foregroundStyle(AIMTheme.amber)
          .padding(.horizontal, 10)
          .padding(.bottom, 9)
      }
    }
    .background(AIMTheme.chatCodeSurface)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }
}

private struct ChatCopyButton: View {
  let text: String
  let label: String
  let emphasized: Bool
  @State private var copied = false

  var body: some View {
    Button {
      #if !AI_MANAGER_PREVIEW
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      #endif
      copied = true
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.2))
        copied = false
      }
    } label: {
      AIMIcon(name: copied ? .check : .copy, size: 10)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
    .foregroundStyle(copied ? AIMTheme.green : AIMTheme.muted)
    .opacity(emphasized || copied ? 1 : 0.48)
    .help(copied ? "Copied" : label)
    .accessibilityLabel(copied ? "Copied" : label)
  }

}

private struct BackupPage: View {
  @ObservedObject var model: AccountViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var hasAutomaticRecovery: Bool {
    model.status?.pendingRecovery.contains { $0.phase != .conflicted } == true
  }
  var body: some View {
    AIMScrollView {
      VStack(spacing: 8) {
        AIMPanel(title: "Pending operations") {
          VStack(spacing: 0) {
            if let operations = model.status?.pendingRecovery, !operations.isEmpty {
              ForEach(Array(operations.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 0) {
                  HStack(spacing: 12) {
                    AIMIcon(name: .warning, size: 15).foregroundStyle(AIMTheme.amber)
                    VStack(alignment: .leading, spacing: 3) {
                      Text(item.kind.capitalized).font(AIMTheme.sans(12, weight: .semibold))
                      Text(item.destination.path).font(AIMTheme.mono(9)).foregroundStyle(
                        AIMTheme.muted
                      ).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(item.destination.path)
                    }
                    Spacer()
                    WarningCopyButton(label: "Copy backup warning") {
                      model.copyWarnings([
                        "Pending \(item.kind) operation (\(item.phase.rawValue))\nDestination: \(item.destination.path)"
                      ])
                    }
                    Badge(text: item.phase.rawValue, color: AIMTheme.amber)
                  }.padding(.horizontal, 16).frame(minHeight: 44)
                  if item.phase == .conflicted {
                    HStack(spacing: 6) {
                      Text("Both versions are protected. Choose which version to keep.")
                        .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
                      Spacer()
                      AIMButton(title: "Keep current", disabled: model.isBusy) {
                        Task { await model.resolveRecoveryConflict(item, choice: .preserveCurrent) }
                      }
                      AIMButton(title: "Restore backup", tone: .danger, disabled: model.isBusy) {
                        Task { await model.resolveRecoveryConflict(item, choice: .restoreBackup) }
                      }
                    }.padding(.horizontal, 16).padding(.bottom, 6)
                  }
                }.background(index.isMultiple(of: 2) ? .clear : AIMTheme.panel2.opacity(0.55))
              }
            } else {
              Text("No interrupted backup work needs attention.").font(AIMTheme.sans(12))
                .foregroundStyle(AIMTheme.muted).padding(16).frame(
                  maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        AIMPanel(title: "Backup policy") {
          VStack(spacing: 0) {
            DetailRow(
              label: "Before import", value: "Review destination, conflicts, and required space")
            DetailRow(
              label: "During import", value: "Back up, stage, verify, then publish", zebra: true)
            DetailRow(
              label: "On failure", value: "Keep prior credentials and preserve a backup journal")
          }
        }
        HStack {
          Text("Backups never delete source data.").font(AIMTheme.sans(11)).foregroundStyle(
            AIMTheme.muted)
          Spacer()
          AIMButton(
            title: "Finish pending work", icon: .backup, tone: .primary,
            disabled: !hasAutomaticRecovery || model.isBusy
          ) { Task { await model.recover() } }
        }.padding(12).background(AIMTheme.panel)
          .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
        #if AI_MANAGER_PREVIEW
        if model.isDemo { BackupExamples(model: model) }
        #endif
        Group {
          if let notice = model.notice {
            Notice(text: notice, tone: AIMTheme.blue)
              .transition(reduceMotion ? .identity : .opacity)
          }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.notice)
      }
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.top, 12).padding(.bottom, 24)
  }
}

#if AI_MANAGER_PREVIEW
private struct BackupExamples: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    AIMPanel(title: "Backup examples") {
      VStack(spacing: 0) {
        BackupExampleRow(
          title: "Regular conversation", detail: "Complete snapshot before replacement",
          location: "~/Documents/Switch Backups", state: "Ready", color: AIMTheme.green)
        BackupExampleRow(
          title: "Incremental", detail: "Only changes since the last snapshot",
          location: "Local backup set · 18 MB", state: "Current", color: AIMTheme.blue, zebra: true)
        BackupExampleRow(
          title: "Custom location", detail: "A selected folder outside the default backup location",
          location: "/Volumes/Studio Archive/Codex", state: "Available", color: AIMTheme.green)
        VStack(spacing: 0) {
          BackupExampleRow(
            title: "External drive", detail: "The selected backup volume is disconnected",
            location: "/Volumes/Field SSD/Codex", state: "Offline", color: AIMTheme.amber,
            zebra: true)
          HStack(spacing: 4) {
            Spacer()
            AIMButton(title: "Wait for drive") {
              model.notice = "Demo backup paused until Field SSD reconnects."
            }
            AIMButton(title: "Back up elsewhere", icon: .folder) {
              model.notice = "Demo destination changed. No folder picker was opened."
            }
          }.padding(.horizontal, 16).padding(.bottom, 6).background(AIMTheme.panel2.opacity(0.55))
        }
      }
    }
  }
}

private struct BackupExampleRow: View {
  let title: String, detail: String, location: String, state: String, color: Color
  var zebra = false
  var body: some View {
    HStack(spacing: 12) {
      AIMIcon(name: .backup, size: 14).foregroundStyle(color)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(AIMTheme.sans(11, weight: .semibold))
        Text(detail).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
      }
      Spacer(minLength: 16)
      Text(location).font(AIMTheme.mono(9)).foregroundStyle(AIMTheme.muted).lineLimit(1)
        .truncationMode(.middle).textSelection(.enabled).help(location)
      Badge(text: state, color: color)
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    .background(zebra ? AIMTheme.panel2.opacity(0.55) : .clear)
  }
}
#endif
private struct WarningCopyButton: View {
  let label: String
  var showsTitle = false
  let action: () -> Void
  @State private var copied = false
  @State private var hovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      action()
      withAnimation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state)) { copied = true }
      Task {
        try? await Task.sleep(for: .milliseconds(900))
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state)) { copied = false }
      }
    } label: {
      HStack(spacing: 5) {
        AIMIcon(name: copied ? .check : .copy, size: 12)
        if showsTitle {
          Text(copied ? "Copied" : "Copy warnings")
            .font(AIMTheme.sans(10, weight: .medium))
        }
      }
      .padding(.horizontal, showsTitle ? 9 : 0)
      .frame(minWidth: showsTitle ? 92 : 28, minHeight: 28)
      .foregroundStyle(copied ? AIMTheme.green : AIMTheme.amber)
      .background(hovered ? AIMTheme.controlHover : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
      .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
    .onHover { hovered = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: hovered)
    .help(label)
    .accessibilityLabel(label)
  }
}

private struct WarningList: View {
  let warnings: [String]
  let copy: ([String]) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("\(warnings.count) item\(warnings.count == 1 ? "" : "s") need attention")
          .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
        Spacer()
        WarningCopyButton(label: "Copy all warnings", showsTitle: true) { copy(warnings) }
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 38)
      .background(AIMTheme.panel2.opacity(0.55))
      ForEach(Array(warnings.enumerated()), id: \.offset) { index, warning in
        HStack(alignment: .top, spacing: 10) {
          AIMIcon(name: .warning, size: 13).foregroundStyle(AIMTheme.amber)
          Text(warning).font(AIMTheme.sans(11)).textSelection(.enabled)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index.isMultiple(of: 2) ? Color.clear : AIMTheme.panel2.opacity(0.55))
      }
    }
  }
}

private struct Notice: View {
  let text: String, tone: Color
  var icon: AIMIcon.Name = .info
  var copy: (() -> Void)? = nil
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      AIMIcon(name: icon, size: 14).foregroundStyle(tone)
      Text(text).font(AIMTheme.sans(11)).textSelection(.enabled)
      Spacer()
      if let copy {
        WarningCopyButton(label: "Copy warning", action: copy)
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AIMTheme.panel)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }
}
private struct ErrorBar: View {
  let message: String
  let copy: () -> Void
  let dismiss: () -> Void
  var body: some View {
    HStack(spacing: 10) {
      AIMIcon(name: .warning, size: 14).foregroundStyle(AIMTheme.red)
      Text(message).font(AIMTheme.sans(11)).lineLimit(2).textSelection(.enabled)
      Spacer()
      WarningCopyButton(label: "Copy error", action: copy)
      AIMButton(title: "Dismiss", action: dismiss)
    }.padding(12).background(AIMTheme.panel)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }
}

private struct ProviderIcon: View {
  let providerID: ProviderID

  var body: some View {
    Group {
      if let image = AIManagerBrand.providerImage(for: providerID) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .padding(3)
      } else {
        AIMIcon(name: .terminal, size: 15)
          .foregroundStyle(AIMTheme.muted)
      }
    }
    .frame(width: 24, height: 24)
    .background(Color.white)
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .accessibilityHidden(true)
  }
}

private struct AddAccountFlow: View {
  @ObservedObject var model: AccountViewModel
  @State private var hoveredProviderID: ProviderID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var step: Int {
    if model.accountLoginState == .completed { return 3 }
    return model.accountLoginSession == nil ? 1 : 2
  }

  private var selectedProvider: ProviderDescriptor? {
    model.providers.first { $0.id == model.selectedProviderID }
  }

  var body: some View {
    VStack(spacing: 0) {
      ImportHeader(
        title: step == 1 ? "Add Account" : (step == 2 ? "Sign In" : "Account Ready"),
        step: step,
        closeDisabled: model.isBusy,
        labels: ["Provider", "Sign in", "Done"]
      ) {
        model.closeAccountModal()
      }
      Group {
        if let error = model.errorMessage {
          ErrorBar(message: error, copy: { model.copyWarnings([error]) }) {
            model.errorMessage = nil
          }
          .padding(.horizontal, 24).padding(.top, 12)
          .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -3)))
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.errorMessage)

      Group {
        switch step {
        case 1: providerPage
        case 2: signInPage
        default: completedPage
        }
      }
      .id(step)
      .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 3)))
      .disabled(model.isBusy)

      if model.isBusy {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Checking account…").font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
        }
        .padding(10)
        .transition(reduceMotion ? .identity : .opacity)
      }
    }
    .font(AIMTheme.sans(13))
    .foregroundStyle(AIMTheme.ink)
    .background(AIMTheme.panel)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.navigation), value: step)
  }

  private var providerPage: some View {
    VStack(spacing: AIMTheme.modalSectionSpacing) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Choose the tool you want to add.")
          .font(AIMTheme.sans(14, weight: .medium))
        Text("Your current Codex login is saved automatically when Switch first opens.")
          .font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      AIMPanel(title: "Providers") {
        VStack(spacing: 0) {
          ForEach(Array(model.providers.enumerated()), id: \.element.id) { index, provider in
            let available = provider.availability == .enabled
            let selected = model.selectedProviderID == provider.id
            Button {
              model.selectedProviderID = provider.id
            } label: {
              HStack(spacing: 12) {
                ProviderIcon(providerID: provider.id)
                VStack(alignment: .leading, spacing: 3) {
                  Text(provider.displayName).font(AIMTheme.sans(12, weight: .semibold))
                  Text(available ? "Account switching and usage are supported." : unavailableCopy(provider))
                    .font(AIMTheme.sans(10))
                    .foregroundStyle(selected ? AIMTheme.activeInk.opacity(0.74) : AIMTheme.muted)
                    .lineLimit(1)
                }
                Spacer()
                if available {
                  AIMIcon(name: selected ? .checkSquare : .square, size: 14)
                } else {
                  Badge(
                    text: "Unavailable", color: AIMTheme.disabledControl,
                    ink: AIMTheme.disabledInk)
                }
              }
              .padding(.horizontal, AIMTheme.panelContentInset)
              .frame(height: 62)
              .foregroundStyle(selected ? AIMTheme.activeInk : AIMTheme.ink)
              .background(
                selected
                  ? AIMTheme.active
                  : (hoveredProviderID == provider.id
                    ? AIMTheme.listHover
                    : (index.isMultiple(of: 2) ? AIMTheme.panel : AIMTheme.listStripe))
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(AIMPressButtonStyle())
            .disabled(!available)
            .opacity(available ? 1 : 0.64)
            .onHover { hoveredProviderID = $0 && available ? provider.id : nil }
            .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: hoveredProviderID)
            .accessibilityLabel(provider.displayName)
            .accessibilityHint(available ? "Available" : unavailableCopy(provider))
          }
        }
      }
      .frame(maxHeight: .infinity)

      HStack(spacing: 6) {
        AIMButton(title: "Advanced Import…", icon: .folder, disabled: model.isBusy) {
          Task { await model.beginAdvancedImport() }
        }
        Spacer()
        AIMButton(
          title: "Continue", tone: .primary,
          disabled: selectedProvider?.availability != .enabled || model.isBusy
        ) {
          Task { await model.startAccountLogin() }
        }
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.top, 18)
    .padding(.bottom, 24)
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private var signInPage: some View {
    VStack(spacing: AIMTheme.modalSectionSpacing) {
      AIMPanel(title: "Codex sign-in") {
        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .top, spacing: 12) {
            AIMIcon(
              name: model.accountLoginState == .needsAttention ? .warning : .account,
              size: 19
            )
            .foregroundStyle(
              model.accountLoginState == .needsAttention ? AIMTheme.amber : AIMTheme.blue)
            VStack(alignment: .leading, spacing: 5) {
              Text("Finish signing in to Codex")
                .font(AIMTheme.sans(18, weight: .semibold))
              Text(
                "Codex is using a private temporary home. Your current account, settings, and chats stay unchanged while you sign in."
              )
              .font(AIMTheme.sans(12))
              .foregroundStyle(AIMTheme.muted)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          if let message = model.accountLoginMessage {
            Notice(
              text: message,
              tone: model.accountLoginState == .needsAttention ? AIMTheme.amber : AIMTheme.blue
            )
          }
          if model.accountLoginState == .credentialChoiceRequired {
            VStack(alignment: .leading, spacing: 8) {
              Text("This account is already saved with different access.")
                .font(AIMTheme.sans(12, weight: .semibold))
              HStack(spacing: 6) {
                AIMButton(title: "Use new sign-in", tone: .primary) {
                  Task { await model.checkAccountLogin(credentialChoice: .useImported) }
                }
                AIMButton(title: "Keep saved access") {
                  Task { await model.checkAccountLogin(credentialChoice: .keepShared) }
                }
              }
            }
          } else {
            Text("When the browser says sign-in is complete, return to Switch and check the account.")
              .font(AIMTheme.sans(11))
              .foregroundStyle(AIMTheme.muted)
          }
        }
        .padding(20)
      }
      .frame(maxHeight: .infinity)

      HStack(spacing: 6) {
        AIMButton(title: "Cancel sign-in") {
          Task { await model.cancelAccountLogin() }
        }
        Spacer()
        if model.accountLoginState != .credentialChoiceRequired {
          AIMButton(title: "Check Now", icon: .refresh, tone: .primary) {
            Task { await model.checkAccountLogin() }
          }
        }
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.top, 18)
    .padding(.bottom, 24)
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private var completedPage: some View {
    VStack(spacing: AIMTheme.modalSectionSpacing) {
      AIMPanel(title: "Ready") {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 10) {
            AIMIcon(name: .success, size: 22).foregroundStyle(AIMTheme.green)
            Text(model.selectedAccount?.identity.heroName ?? "Codex account")
              .font(AIMTheme.sans(19, weight: .semibold))
          }
          Text(model.accountLoginMessage ?? "The account is saved and ready to use.")
            .font(AIMTheme.sans(12)).foregroundStyle(AIMTheme.muted)
          Text("Switch preserved the current settings and chat library.")
            .font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      HStack {
        AIMButton(title: "Use for new Codex sessions", tone: .primary, disabled: model.isBusy) {
          Task { await model.switchDefault() }
        }
        AIMButton(title: "Open Codex", icon: .play, disabled: model.isBusy) {
          Task { await model.openAccount() }
        }
        Spacer()
        AIMButton(title: "Done") { model.closeAccountModal() }
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.top, 18)
    .padding(.bottom, 24)
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private func unavailableCopy(_ provider: ProviderDescriptor) -> String {
    provider.unavailableReason ?? "Account setup is not available in this version."
  }
}

private struct ImportFlow: View {
  @ObservedObject var model: AccountViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(spacing: 0) {
      ImportHeader(
        title: title,
        step: step,
        closeDisabled: model.isBusy
      ) {
        model.closeAccountModal()
      }
      Group {
        if let error = model.errorMessage {
          ErrorBar(message: error, copy: { model.copyWarnings([error]) }) {
            model.errorMessage = nil
          }
          .padding(.horizontal, 24).padding(.top, 12)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -3)))
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.errorMessage)
      Group {
        if let result = model.importResult {
          ImportResultPage(result: result, model: model)
        } else if let plan = model.importPlan {
          ImportReviewPage(plan: plan, model: model)
        } else {
          SourcePage(model: model)
        }
      }
      .id(step)
      .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 3)))
      .disabled(model.isBusy)
      Group {
        if model.isBusy {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…").font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
          }.padding(10).transition(reduceMotion ? .identity : .opacity)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.isBusy)
    }.font(AIMTheme.sans(13)).foregroundStyle(AIMTheme.ink).background(AIMTheme.panel).frame(
      maxWidth: .infinity, maxHeight: .infinity
    )
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.navigation), value: step)
  }
  private var step: Int { model.importResult != nil ? 3 : model.importPlan != nil ? 2 : 1 }
  private var title: String {
    step == 1 ? "Import Account" : step == 2 ? "Review Import" : "Import Result"
  }
}

private struct ImportHeader: View {
  let title: String
  let step: Int
  let closeDisabled: Bool
  var labels = ["Source", "Review", "Done"]
  let close: () -> Void
  @State private var closeHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      Text(title)
        .font(AIMTheme.sans(22, weight: .semibold))
        .tracking(-0.55)
        .lineLimit(1)
        .padding(.leading, AIMTheme.modalOuterInset)
      Spacer(minLength: AIMTheme.modalOuterInset)
      ImportSteps(step: step, labels: labels)
        .fixedSize(horizontal: true, vertical: true)
        .padding(.trailing, 16)
      Button(action: close) {
        AIMIcon(name: .close, size: 15)
          .foregroundStyle(closeHovered && !closeDisabled ? Color.white : AIMTheme.ink)
          .frame(
            width: AIMTheme.windowControlSize,
            height: AIMTheme.modalTitlebarHeight
          )
          .background(
            closeHovered && !closeDisabled
              ? Color(nsColor: .systemRed)
              : AIMTheme.panel3
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(AIMPressButtonStyle())
      .keyboardShortcut(.cancelAction)
      .accessibilityLabel("Close import")
      .accessibilityIdentifier("import-modal-close")
      .disabled(closeDisabled)
      .opacity(closeDisabled ? 0.45 : 1)
      .onHover { closeHovered = $0 && !closeDisabled }
      .animation(
        reduceMotion ? nil : .easeOut(duration: AIMMotion.hover),
        value: closeHovered
      )
      .animation(
        reduceMotion ? nil : .easeOut(duration: AIMMotion.state),
        value: closeDisabled
      )
    }
    .frame(height: AIMTheme.modalTitlebarHeight)
    .background(AIMTheme.panel2)
    .accessibilityIdentifier("import-modal-titlebar")
  }
}

private struct ImportSteps: View {
  let step: Int
  let labels: [String]
  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
        HStack(spacing: 5) {
          Text("\(index + 1)").font(AIMTheme.mono(9, weight: .semibold))
          Text(label).font(AIMTheme.sans(10, weight: .medium))
        }
        .foregroundStyle(index < step ? AIMTheme.activeInk : AIMTheme.muted)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(index < step ? AIMTheme.active : AIMTheme.control)
      }
    }.clipShape(RoundedRectangle(cornerRadius: 3)).accessibilityElement(children: .ignore)
      .accessibilityLabel("Step \(step) of 3")
      .accessibilityIdentifier("import-modal-steps")
  }
}

private struct SourcePage: View {
  @ObservedObject var model: AccountViewModel
  @State private var hoveredSourceID: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  var body: some View {
    VStack(spacing: AIMTheme.modalSectionSpacing) {
      Text("Choose a provider and one of its data folders.")
        .font(AIMTheme.sans(12))
        .foregroundStyle(AIMTheme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
      AIMPanel(title: "Provider") {
        HStack(spacing: 4) {
          Choice(title: "Codex", selected: model.selectedProviderID == .codex) {
            model.selectedProviderID = .codex
          }
          Spacer()
        }.padding(.horizontal, AIMTheme.panelContentInset).padding(.vertical, 8)
      }
      AIMPanel(title: "Source") {
        AIMScrollView {
          LazyVStack(spacing: 0) {
            if model.discoveries.isEmpty {
              Text("No Codex accounts found. Refresh or choose another folder.")
                .font(AIMTheme.sans(11))
                .foregroundStyle(AIMTheme.muted)
                .padding(AIMTheme.panelContentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(model.discoveries.enumerated()), id: \.element.id) { index, source in
              let supported = source.support == .supportedChatGPT
              let selected = source.id == model.selectedSourceID
              Button {
                model.selectedSourceID = source.id
              } label: {
                HStack(alignment: .top, spacing: 12) {
                  AIMIcon(
                    name: selected ? .checkSquare : .square,
                    size: 14
                  )
                  .padding(.top, 2)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(source.identity?.displayName ?? source.support.label).font(
                      AIMTheme.sans(12, weight: .medium))
                    Text(source.path.path).font(AIMTheme.mono(11)).foregroundStyle(
                      selected ? AIMTheme.activeInk : AIMTheme.muted)
                      .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                      .help(source.path.path)
                    Text(
                      "\(source.settings.count) settings · \(source.history.activeTranscripts) active · \(source.history.archivedTranscripts) archived"
                    ).font(AIMTheme.mono(10)).foregroundStyle(
                      selected ? AIMTheme.activeInk : AIMTheme.muted)
                    if let reason = source.inspectionError, !supported {
                      Text(reason).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.amber)
                        .lineLimit(2)
                    }
                  }
                  Spacer()
                  Badge(
                    text: source.support.label,
                    color: source.support == .supportedChatGPT ? AIMTheme.green : AIMTheme.amber
                  )
                  .padding(.top, 1)
                }.padding(.horizontal, AIMTheme.panelContentInset).padding(.vertical, 10)
                  .frame(minHeight: 64).background(
                  selected
                    ? AIMTheme.active.opacity(0.70)
                    : (hoveredSourceID == source.id
                      ? AIMTheme.panel2
                      : (index.isMultiple(of: 2) ? .clear : AIMTheme.panel2.opacity(0.55)))
                ).contentShape(Rectangle())
                  .foregroundStyle(
                    selected ? AIMTheme.activeInk : AIMTheme.ink)
                  .opacity(isEnabled && supported ? 1 : 0.58)
              }.buttonStyle(AIMPressButtonStyle())
                .disabled(!supported)
                .help(source.inspectionError ?? source.path.path)
                .onHover { hoveredSourceID = $0 && isEnabled && supported ? source.id : nil }
                .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: hoveredSourceID)
                .animation(
                  reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.selectedSourceID)
                .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: isEnabled)
            }
          }
        }
      }.frame(maxHeight: .infinity)
      AIMPanel(title: "Import scope") {
        HStack(spacing: 4) {
          Choice(title: "Account access only", selected: model.importMode == .authOnly) {
            model.importMode = .authOnly
          }
          Choice(title: "Account access, settings, and chats", selected: model.importMode == .full) {
            model.importMode = .full
          }
          Spacer()
        }.padding(.horizontal, AIMTheme.panelContentInset).padding(.vertical, 8)
      }
      Text(
        model.importMode == .authOnly
          ? "Saves account access. Settings and chats stay in the current Codex home. The source stays unchanged."
          : "Reviews shared settings conflicts and adds source chats to the merged library. Everything affected is backed up first."
      ).font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted).frame(
        maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 4) {
        AIMButton(title: "Choose Codex folder…", icon: .folder) {
          Task { await model.chooseSource() }
        }
        AIMButton(title: "Refresh", icon: .refresh) { Task { await model.discover() } }
        Spacer()
        AIMButton(
          title: "Review import", tone: .primary,
          disabled: model.selectedSourceID == nil
            || model.discoveries.first(where: { $0.id == model.selectedSourceID })?.support
              != .supportedChatGPT
        ) { Task { await model.reviewImport() } }
      }
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.top, 16).padding(.bottom, 24).frame(
      maxHeight: .infinity, alignment: .top)
  }
}
private struct Choice: View {
  let title: String, selected: Bool, action: () -> Void
  @State private var hover = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        AIMIcon(name: selected ? .checkSquare : .square, size: 14)
        Text(title)
      }.font(AIMTheme.sans(11, weight: .medium)).padding(.horizontal, 10).frame(height: 30)
        .foregroundStyle(
          !isEnabled ? AIMTheme.disabledInk : (selected ? AIMTheme.activeInk : AIMTheme.ink)
        ).background(
          !isEnabled
            ? AIMTheme.disabledControl
            : (selected ? AIMTheme.active : (hover ? AIMTheme.controlHover : AIMTheme.control)))
        .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
    }.buttonStyle(AIMPressButtonStyle()).accessibilityAddTraits(selected ? .isSelected : [])
      .onHover { hover = $0 && isEnabled }
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: hover)
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: selected)
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: isEnabled)
  }
}

private struct ImportReviewPage: View {
  let plan: ImportPlan
  @ObservedObject var model: AccountViewModel
  private var complete: Bool {
    plan.conflicts.allSatisfy {
      model.conflictChoices[$0.relativePath] != nil
        && (model.conflictChoices[$0.relativePath] != .useImported || $0.externalTarget == nil
          || $0.externalTargetBytes != nil)
    }
  }
  var body: some View {
    VStack(spacing: AIMTheme.modalSectionSpacing) {
      AIMScrollView {
        VStack(spacing: AIMTheme.modalSectionSpacing) {
          AIMPanel(title: "Plan") {
            VStack(spacing: 0) {
              DetailRow(label: "Account", value: plan.identity.displayName)
              DetailRow(label: "Saved auth", value: plan.credentialDestination.path, zebra: true)
              if plan.mode == .full {
                DetailRow(label: "Shared Codex home", value: plan.sharedDestination.path)
                DetailRow(label: "Imported account data", value: plan.destination.path, zebra: true)
              }
              DetailRow(label: "Backup", value: plan.backup.path)
              DetailRow(
                label: "Space needed",
                value: ByteCountFormatter.string(
                  fromByteCount: plan.requiredBytes, countStyle: .file), zebra: true)
            }
          }
          if !plan.warnings.isEmpty {
            AIMPanel(title: "Warnings") {
              WarningList(warnings: plan.warnings) { model.copyWarnings($0) }
            }
          }
          if !plan.conflicts.isEmpty {
            AIMPanel(title: "Conflicts") {
              VStack(spacing: 0) {
                ForEach(plan.conflicts) { conflict in
                  VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.relativePath).font(AIMTheme.mono(11, weight: .semibold))
                    Text(
                      conflict.affectsAllAccounts
                        ? "This settings choice affects every account opened from this Mac."
                        : "The saved credential differs from this source."
                    ).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
                    HStack(spacing: 4) {
                      Choice(
                        title: conflict.affectsAllAccounts ? "Keep shared" : "Keep saved",
                        selected: model.conflictChoices[conflict.relativePath] == .keepShared
                      ) { model.conflictChoices[conflict.relativePath] = .keepShared }
                      Choice(
                        title: "Use imported",
                        selected: model.conflictChoices[conflict.relativePath] == .useImported
                      ) { model.conflictChoices[conflict.relativePath] = .useImported }
                      if conflict.externalTarget != nil
                        && model.conflictChoices[conflict.relativePath] == .useImported
                        && conflict.externalTargetBytes == nil
                      {
                        AIMButton(title: "Review linked data", disabled: model.isBusy) {
                          Task { await model.reviewExternalSetting(conflict.relativePath) }
                        }
                      }
                    }
                  }.padding(.horizontal, AIMTheme.panelContentInset).padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                    Rectangle().fill(AIMTheme.lineSoft).frame(height: 1)
                  }
                }
              }
            }
          }
          AIMPanel(title: "Manifest · \(plan.manifest.filter(\.selected).count) selected") {
            VStack(spacing: 0) {
              ForEach(plan.manifest) { entry in
                HStack {
                  AIMIcon(name: entry.selected ? .check : .minimize, size: 12).foregroundStyle(
                    entry.selected ? AIMTheme.green : AIMTheme.faint)
                  Text(entry.relativePath).font(AIMTheme.mono(10))
                  Spacer()
                  Text(entry.disposition).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
                }.padding(.horizontal, 16).frame(height: 36)
              }
            }
          }
        }
      }
      HStack {
        AIMButton(title: "Back") { model.resetImport() }
        Spacer()
        AIMButton(title: "Import account", tone: .primary, disabled: !complete || model.isBusy) {
          Task { await model.commitImport() }
        }
      }
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.top, 16).padding(.bottom, 24)
  }
}
private struct ImportResultPage: View {
  let result: ImportResult
  @ObservedObject var model: AccountViewModel
  var body: some View {
    VStack(spacing: AIMTheme.modalSectionSpacing) {
      AIMScrollView {
        VStack(spacing: AIMTheme.modalSectionSpacing) {
          AIMPanel(title: result.unresolved.isEmpty ? "Import complete" : "Review required") {
            HStack(spacing: 14) {
              ZStack {
                result.unresolved.isEmpty ? AIMTheme.green : AIMTheme.amber
                AIMIcon(name: result.unresolved.isEmpty ? .check : .warning, size: 24)
                  .foregroundStyle(AIMTheme.statusInk)
              }.frame(width: 48, height: 48)
              VStack(alignment: .leading, spacing: 3) {
                Text(result.account.identity.heroName).font(AIMTheme.sans(18, weight: .semibold))
                Text(result.verification.detail).font(AIMTheme.sans(11)).foregroundStyle(
                  AIMTheme.muted)
              }
              Spacer()
            }.padding(16)
          }
          AIMPanel(title: "Result") {
            VStack(spacing: 0) {
              DetailRow(label: "Saved auth", value: result.account.credentialFile.path)
              DetailRow(label: "Backup", value: result.backup.path, zebra: true)
              DetailRow(
                label: "Imported",
                value: "\(result.importedFiles) files and \(result.importedChats) chats")
            }
          }
          if !result.unresolved.isEmpty {
            AIMPanel(title: "Unresolved items") {
              WarningList(warnings: result.unresolved) { model.copyWarnings($0) }
            }
          }
          Notice(
            text:
              "The imported account is ready. Choose Use for new Codex sessions when you want to switch.",
            tone: AIMTheme.blue, icon: .success)
        }
      }
      HStack {
        Spacer()
        AIMButton(title: "Done", tone: .primary) {
          model.closeAccountModal()
        }
      }
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.top, 16).padding(.bottom, 24)
  }
}

extension AccountIdentity {
  fileprivate var heroName: String { email ?? accountID ?? "Unresolved account" }
  fileprivate var displayName: String {
    if let email, let workspaceID { return "\(email) · \(workspaceID)" }
    return email ?? accountID ?? "Unresolved account"
  }
}
extension VerificationState {
  fileprivate var label: String {
    switch self {
    case .imported: "Imported"
    case .needsSignIn: "Needs sign-in"
    case .verifiedLocally: "Verified locally"
    case .verifiedWithCodex: "Verified with Codex"
    case .unsupported: "Unsupported"
    }
  }
  fileprivate var color: Color {
    switch self {
    case .verifiedLocally, .verifiedWithCodex: AIMTheme.green
    case .needsSignIn: AIMTheme.amber
    case .unsupported: AIMTheme.red
    case .imported: AIMTheme.blue
    }
  }
}
extension SourceSupport {
  fileprivate var label: String {
    switch self {
    case .supportedChatGPT: "ChatGPT account"
    case .apiKey: "API key"
    case .missingAuth: "Missing auth"
    case .malformedAuth: "Malformed auth"
    case .keychainOnly: "Keychain only"
    case .unknown: "Unknown format"
    }
  }
}
