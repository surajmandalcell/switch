import AIManagerCore
import AppKit
import SwiftUI

@MainActor final class AIManagerWindow: NSWindow {
  static let fixedSize = NSSize(width: 1120, height: 740)
  static let frameAutosaveName = "AIManagerMainWindow"
  static let cornerRadius: CGFloat = 3
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
    host.wantsLayer = true
    host.layer?.cornerRadius = AIManagerWindow.cornerRadius
    host.layer?.masksToBounds = true
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
    case .cleanup: .cleanup
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
    case .cleanup: "Clean up conversations and cached data"
    case .settings: "App behavior and data locations"
    }
  }
}

struct AccountWindow: View {
  @ObservedObject var model: AccountViewModel
  @StateObject private var target = WindowTarget()
  @State private var page: AIManagerPage = .accounts
  @AppStorage("appearanceMode") private var appearanceMode = "system"
  @AppStorage("keyboardFocusIndicators") private var showFocusIndicators = false
  @AppStorage(AIMTranslucency.preferenceKey) private var translucency = AIMTranslucency.initialValue
  @State private var refreshHovered = false
  @State private var sidebarHover = AIMSidebarHover()
  @Environment(\.colorScheme) private var systemScheme
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
              case .accounts: AccountsPage(model: model, sidebarHover: sidebarHover)
              case .backup: BackupPage(model: model)
              case .history: HistoryPage(model: model)
              case .cleanup: CleanupPage(model: model)
              case .settings:
                SettingsPage(model: model, showFocusIndicators: $showFocusIndicators)
              }
            }
            .id(page)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 3)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .environment(\.aimSurfaceOpacity,
            AIMTranslucency.opacity(translucency, reduceTransparency: reduceTransparency))
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
              height: min(
                model.accountModalMode == .add
                  ? AIMTheme.addAccountModalHeight : AIMTheme.modalHeight,
                geometry.size.height - 48
              )
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
        AIMTheme.canvas.opacity(AIMTranslucency.opacity(
          translucency, reduceTransparency: reduceTransparency))
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.navigation), value: page)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.modal), value: model.showImport)
    .environment(\.aimDarkMode, dark)
    .environment(\.aimFocusIndicatorsEnabled, showFocusIndicators)
    .environment(\.aimCopyPath, model.copyPath)
    .focusEffectDisabled(!showFocusIndicators)
    .preferredColorScheme(themeOverride)
    .background(
      WindowReader { window in
        target.window = window
        applyAppearance(to: window)
        applyFocusPolicy(to: window)
      }
    ).ignoresSafeArea(.container, edges: .top)
    .onAppear { AIManagerBrand.installApplicationIcon(dark: dark) }
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
    .task(id: model.hasLoaded, priority: .utility) {
      if model.hasLoaded { await model.watchActivity() }
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
          sidebarHover: sidebarHover, hoverID: item.rawValue,
          iconSize: item.railIconSize
        ) { page = item }
      }
      Spacer()
      RailButton(icon: dark ? .sun : .moon, label: dark ? "Light mode" : "Dark mode", active: false,
        sidebarHover: sidebarHover, hoverID: "appearance")
      {
        withAnimation(reduceMotion ? nil : .easeOut(duration: AIMMotion.theme)) {
          appearanceMode = dark ? "light" : "dark"
        }
      }
      RailButton(icon: .plus, label: "Add account", active: false, disabled: model.isBusy,
        sidebarHover: sidebarHover, hoverID: "addAccount") {
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
        Text(page.rawValue).font(AIMTheme.sans(22, weight: .semibold)).tracking(-0.35).lineLimit(1)
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
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: model.isBusy)
      .help(refreshHelp)
      .accessibilityLabel(refreshAccessibilityLabel)
      .accessibilityHint(refreshHelp)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
      .padding(.horizontal, AIMTheme.modalOuterInset)
      .frame(height: AIMTheme.topbarHeight)
      .background(AIMTheme.canvas)
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
          minimizeHover ? AIMTheme.windowControlInk : AIMTheme.muted
        )
        .frame(width: AIMTheme.windowControlSize, height: AIMTheme.windowControlSize)
        .background {
          AIMHoverBackground(base: AIMTheme.minimizeControl,
            highlight: AIMTheme.minimizeHover, hovered: minimizeHover)
        }
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
      Button(action: close) {
        AIMIcon(name: .close, size: 15).foregroundStyle(closeHover ? Color.white : AIMTheme.closeHover)
          .frame(width: AIMTheme.windowControlSize, height: AIMTheme.windowControlSize)
          .background(alignment: .leading) {
            ZStack {
              AIMTheme.rail
              AIMTheme.closeHover.opacity(closeHover ? 1 : 0)
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

struct RailButton: View {
  let icon: AIMIcon.Name, label: String, active: Bool
  var disabled = false
  let sidebarHover: AIMSidebarHover
  let hoverID: String
  var iconSize = AIMTheme.railIconSize
  let action: () -> Void
  private var hover: Bool { sidebarHover.target == hoverID }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  private var unavailable: Bool { disabled || !isEnabled }
  var body: some View {
    Button(action: action) {
      AIMIcon(name: icon, size: iconSize).frame(width: 48, height: 48).foregroundStyle(
        active ? AIMTheme.activeInk : (hover && !unavailable ? AIMTheme.ink : AIMTheme.railIdle)
      ).background {
        AIMHoverBackground(base: active ? AIMTheme.active : .clear,
          highlight: AIMTheme.panel2, hovered: hover && !active && !unavailable)
          .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: active)
          .allowsHitTesting(false)
      }
        .contentShape(Rectangle())
    }.buttonStyle(AIMPressButtonStyle()).disabled(disabled).help(label).accessibilityLabel(label).accessibilityAddTraits(
      active ? .isSelected : []
    ).onHover { sidebarHover.update(hoverID, inside: $0 && !unavailable) }
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: unavailable)
  }
}
enum ButtonTone { case normal, primary, danger }
struct AIMButton: View {
  let title: String
  var icon: AIMIcon.Name?
  var tone: ButtonTone = .normal
  var disabled = false
  var active = false
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
              ? AIMTheme.primaryInk : (tone == .danger ? AIMTheme.statusInk : (active ? AIMTheme.blue : AIMTheme.ink)))
        ).background {
          AIMHoverBackground(
            base: unavailable ? AIMTheme.disabledControl
              : tone == .primary ? AIMTheme.ink
              : tone == .danger ? AIMTheme.red
              : active ? AIMTheme.blue.opacity(0.10) : AIMTheme.control,
            highlight: tone == .primary ? AIMTheme.primaryHover
              : tone == .danger ? AIMTheme.statusInk.opacity(0.08) : AIMTheme.controlHover,
            hovered: hover && !unavailable)
        }.overlay {
          if tone == .normal {
            RoundedRectangle(cornerRadius: 3).stroke(AIMTheme.line, lineWidth: 1)
          }
          if focused, focusIndicatorsEnabled {
            RoundedRectangle(cornerRadius: 3).stroke(AIMTheme.blue, lineWidth: 2)
          }
        }.clipShape(RoundedRectangle(cornerRadius: 3))
    }
    .buttonStyle(AIMPressButtonStyle()).focused($focused).disabled(disabled).onHover {
      hover = $0 && !unavailable
    }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: unavailable)
  }
}
struct AIMIconButton: View {
  let icon: AIMIcon.Name
  let label: String
  var tone: ButtonTone = .normal
  var disabled = false
  var active = false
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
            : (tone == .danger
              ? (hover ? AIMTheme.statusInk : AIMTheme.red)
              : (active ? AIMTheme.blue : (hover ? AIMTheme.ink : AIMTheme.muted)))
        )
        .background {
          AIMHoverBackground(base: active && !unavailable ? AIMTheme.blue.opacity(0.10) : .clear,
            highlight: tone == .danger ? AIMTheme.red : AIMTheme.controlHover,
            hovered: hover && !unavailable)
        }
        .overlay {
          if focused, focusIndicatorsEnabled {
            RoundedRectangle(cornerRadius: 3).stroke(AIMTheme.blue, lineWidth: 2)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
    .background {
      if icon == .copy { AIMCopyCursor(enabled: !unavailable).allowsHitTesting(false) }
    }
    .focused($focused)
    .disabled(disabled)
    .onHover { hover = $0 && !unavailable }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: unavailable)
    .help(label)
    .accessibilityLabel(label)
  }
}
private struct Badge: View {
  let text: String, color: Color
  var ink: Color = AIMTheme.statusInk
  var body: some View {
    Text(text).font(AIMTheme.sans(10, weight: .medium)).padding(.horizontal, 6)
      .frame(height: 18).foregroundStyle(ink).background(color).clipShape(
        RoundedRectangle(cornerRadius: 3))
  }
}

enum AccountActionCopy {
  static let use = "Set as Default"
  static let usingDefault = "Using as default"
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
  let sidebarHover: AIMSidebarHover
  @State private var importHovered = false
  @State private var pendingDeletion: PendingAccountDeletion?
  @State private var dropTargetID: UUID?
  @GestureState private var isDraggingAccount = false
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
                    isDefault: account.id == model.status?.defaultAccountID, sidebarHover: sidebarHover)
                }
                .buttonStyle(AIMPressButtonStyle())
                .contextMenu {
                  accountContextMenu(for: account)
                }
                .highPriorityGesture(
                  DragGesture(minimumDistance: 6)
                    .updating($isDraggingAccount) { _, dragging, _ in dragging = true }
                    .onChanged { value in
                      dropTargetID = accountDropTarget(for: account.id, at: value.location, model: model)
                    }
                    .onEnded { value in
                      defer { dropTargetID = nil }
                      guard let target = accountDropTarget(for: account.id, at: value.location, model: model) else { return }
                      Task { await model.moveAccount(account.id, to: target) }
                    }
                )
                .overlay {
                  if isDraggingAccount && dropTargetID == account.id {
                    Rectangle().stroke(AIMTheme.blue.opacity(0.7), lineWidth: 1)
                      .allowsHitTesting(false)
                  }
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
              .background {
                AIMHoverBackground(base: AIMTheme.panel2, highlight: AIMTheme.controlHover,
                  hovered: importHovered && !model.isBusy && model.hasLoaded)
              }
          }.buttonStyle(AIMPressButtonStyle()).keyboardShortcut("i", modifiers: [.command])
            .disabled(model.isBusy || !model.hasLoaded)
            .onHover { importHovered = $0 && !model.isBusy && model.hasLoaded }
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
        message: Text(deletionMessage(for: deletion.account)),
        primaryButton: .destructive(Text("Delete account")) {
          Task { await model.deleteAccount(deletion.account.id) }
        },
        secondaryButton: .cancel())
    }
  }

  @ViewBuilder
  private func accountContextMenu(for account: AccountRecord) -> some View {
    let isDefault = account.id == model.status?.defaultAccountID
    Button(isDefault ? AccountActionCopy.usingDefault : AccountActionCopy.use) {
      Task { await model.switchDefault(to: account.id) }
    }
    .disabled(model.isBusy)
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
    Button("Move up") {
      if let target = model.adjacentAccountID(to: account.id, offset: -1) {
        Task { await model.moveAccount(account.id, to: target) }
      }
    }.disabled(model.isBusy || model.adjacentAccountID(to: account.id, offset: -1) == nil)
    Button("Move down") {
      if let target = model.adjacentAccountID(to: account.id, offset: 1) {
        Task { await model.moveAccount(account.id, to: target) }
      }
    }.disabled(model.isBusy || model.adjacentAccountID(to: account.id, offset: 1) == nil)
    Divider()
    Button(AccountActionCopy.delete, role: .destructive) {
      prepareDeletion(of: account)
    }
    .disabled(model.isBusy || !model.canDeleteAccount(account.id))
  }

  private func prepareDeletion(of account: AccountRecord) {
    guard model.canDeleteAccount(account.id) else {
      model.errorMessage = "No saved account is available as a replacement."
      return
    }
    pendingDeletion = PendingAccountDeletion(account: account)
  }

  private func deletionMessage(for account: AccountRecord) -> String {
    let removal = "Remove this account's saved sign-in from Switch. Conversations and settings stay."
    if account.id == model.status?.defaultAccountID,
       let replacement = model.deletionReplacement(for: account.id) {
      return "\(removal) \(replacement.identity.heroName) will become the default for new Codex sessions."
    }
    return removal
  }
}
@MainActor
func accountDropTarget(for accountID: UUID, at point: CGPoint, model: AccountViewModel) -> UUID? {
  guard !model.isBusy, point.x.isFinite, point.y.isFinite,
    point.x >= 0, point.x <= AIMTheme.listWidth,
    abs(point.y) < CGFloat(model.status?.accounts.count ?? 0) * AccountListRow.height
  else { return nil }
  return model.adjacentAccountID(
    to: accountID, offset: Int(floor(point.y / AccountListRow.height)))
}

struct AccountListRow: View {
  static let height: CGFloat = 44
  let account: AccountRecord, selected: Bool, isDefault: Bool
  let sidebarHover: AIMSidebarHover
  private var hover: Bool { sidebarHover.target == account.id.uuidString }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        Text(account.identity.heroName).font(AIMTheme.sans(12, weight: .medium)).lineLimit(1)
        Spacer()
        if isDefault { AIMIcon(name: .check, size: 11) }
      }
      Text(account.identity.providerID.displayName).font(AIMTheme.sans(10, weight: .medium))
        .foregroundStyle(selected ? AIMTheme.activeInk.opacity(0.75) : AIMTheme.muted).lineLimit(1)
    }.padding(.horizontal, 12).padding(.vertical, 6).frame(
      maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading
    ).foregroundStyle(selected ? AIMTheme.activeInk : AIMTheme.ink).background {
      AIMHoverBackground(base: selected ? AIMTheme.active : .clear,
        highlight: AIMTheme.panel2, hovered: hover && !selected)
        .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: selected)
        .allowsHitTesting(false)
    }.overlay(alignment: .bottom) { Rectangle().fill(AIMTheme.lineSoft).frame(height: 1) }
      .contentShape(Rectangle()).onHover { sidebarHover.update(account.id.uuidString, inside: $0) }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityValue(isDefault ? "Default account" : "Not the default account")
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
        AIMPanel(title: "Identity", importance: .primary, headerAccessories: AnyView(identityStatus)) {
          VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
              Text(account.identity.heroName).font(AIMTheme.sans(20, weight: .semibold))
                .lineLimit(1).textSelection(.enabled)
              Group {
                if let workspaceID = account.identity.workspaceID {
                  Text(workspaceID).font(AIMTheme.mono(10))
                } else {
                  Text("Personal workspace").font(AIMTheme.sans(11))
                }
              }
              .foregroundStyle(AIMTheme.muted).textSelection(.enabled)
            }
            if account.verification.state.attentionLabel != nil {
              Text(account.verification.detail).font(AIMTheme.sans(11)).foregroundStyle(
                AIMTheme.muted
              ).textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 4) { actions }
              VStack(alignment: .leading, spacing: 4) { actions }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        AccountUsagePanel(account: account, model: model)
        AIMPanel(title: "Account details") {
          VStack(spacing: 0) {
            DetailRow(label: "Saved auth", value: account.credentialFile.path)
            DetailRow(label: "Source", value: account.source.path, zebra: true)
            DetailRow(label: "Codex home", value: model.paths.defaultHome.path)
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
          AIMPanel(title: "Account data needs repair") {
            VStack(spacing: 0) {
              ForEach(issues) { issue in
                HStack(spacing: 12) {
                  AIMIcon(name: .warning, size: 15).foregroundStyle(AIMTheme.amber)
                  VStack(alignment: .leading, spacing: 2) {
                    AIMCopyablePath(path: issue.relativePath).font(AIMTheme.mono(11, weight: .semibold))
                    AIMCopyablePath(path: issue.localPath.path).font(AIMTheme.mono(9)).foregroundStyle(
                      AIMTheme.muted
                    )
                  }
                  Spacer()
                  WarningCopyButton(label: "Copy repair warning") {
                    model.copyWarnings([
                      "Account data needs repair: \(issue.relativePath)\nLocation: \(issue.localPath.path)"
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
  private var identityStatus: some View {
    HStack(spacing: 6) {
      if account.id == model.status?.defaultAccountID {
        Badge(text: "Default", color: AIMTheme.green.opacity(0.14), ink: AIMTheme.ink)
      }
      if let attention = account.verification.state.attentionLabel {
        Badge(text: attention, color: account.verification.state.color)
      }
    }
  }
  @ViewBuilder private var actions: some View {
    AIMButton(
      title: account.id == model.status?.defaultAccountID
        ? AccountActionCopy.usingDefault : AccountActionCopy.use,
      icon: account.id == model.status?.defaultAccountID ? .doubleCheck : .check,
      tone: .primary,
      disabled: model.isBusy
    ) { Task { await model.switchDefault() } }
    AccountMenuBarUsageButton(accountID: account.id)
      .id(account.id).disabled(model.isBusy)
    AIMButton(
      title: account.id == model.status?.defaultAccountID
        ? AccountActionCopy.open : AccountActionCopy.useAndOpen,
      icon: .play,
      disabled: model.isBusy
    ) {
      Task { await model.openAccount(account.id) }
    }
    AIMIconButton(icon: .search, label: AccountActionCopy.check, disabled: model.isBusy) {
      Task { await model.checkAccount(account.id) }
    }
    AIMIconButton(icon: .copy, label: AccountActionCopy.copyAuthPath) {
      model.copySavedAuthPath(for: account.id)
    }
    AIMIconButton(
      icon: .trash,
      label: AccountActionCopy.delete,
      tone: .danger,
      disabled: model.isBusy || !model.canDeleteAccount(account.id),
      action: delete)
  }
}

enum UsagePresentation {
  struct Fact: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
  }

  struct ActivityDay: Identifiable, Equatable {
    let date: Date
    let tokens: Int64
    var id: Date { date }
  }

  static func accountFacts(_ snapshot: CodexAccountUsageSnapshot) -> [Fact] {
    var facts: [Fact] = []
    if let allowed = snapshot.rateLimits?.ordinaryUsageAllowed {
      facts.append(Fact(label: "Ordinary usage", value: allowed ? "Available" : "Restricted"))
    }
    if snapshot.account != nil {
      facts.append(Fact(label: "Authentication", value: "Signed in"))
    } else if let required = snapshot.requiresOpenAIAuthentication {
      facts.append(Fact(
        label: "Authentication", value: required ? "Sign-in required" : "Not required"))
    }
    return facts
  }

  static func summaryFacts(_ summary: CodexUsageSummarySnapshot?) -> [Fact] {
    guard let summary else { return [] }
    var facts: [Fact] = []
    if let value = summary.lifetimeTokens {
      facts.append(Fact(label: "Lifetime", value: formatTokens(value)))
    }
    if let value = summary.peakDailyTokens {
      facts.append(Fact(label: "Peak day", value: formatTokens(value)))
    }
    if let value = summary.currentStreakDays {
      facts.append(Fact(label: "Current streak", value: formatDays(value)))
    }
    if let value = summary.longestStreakDays {
      facts.append(Fact(label: "Longest streak", value: formatDays(value)))
    }
    if let value = summary.longestRunningTurnSeconds {
      facts.append(Fact(label: "Longest turn", value: formatDuration(value)))
    }
    return facts
  }

  static func credits(_ credits: CodexCreditsSnapshot?) -> String? {
    guard let credits else { return nil }
    if credits.unlimited == true { return "Unlimited" }
    if let balance = nonempty(credits.balance) { return balance }
    if let hasCredits = credits.hasCredits { return hasCredits ? "Available" : "None" }
    return nil
  }

  static func spendControl(_ reached: Bool?) -> String? {
    reached.map { $0 ? "Reached" : "Not reached" }
  }

  static func hasWindow(_ window: CodexRateLimitWindowSnapshot?) -> Bool {
    window?.usedPercent != nil
  }

  static func hasContent(_ bucket: CodexRateLimitBucketSnapshot) -> Bool {
    hasWindow(bucket.primary) || hasWindow(bucket.secondary) || credits(bucket.credits) != nil
      || spendControl(bucket.spendControlReached) != nil
  }

  static func hasRateLimits(_ bucket: CodexRateLimitBucketSnapshot) -> Bool {
    hasWindow(bucket.primary) || hasWindow(bucket.secondary)
  }

  static func emptyUsageTitle(failure: String?, needsSignIn: Bool) -> String {
    if needsSignIn { return "Sign in to refresh usage" }
    return failure == nil ? "Usage has not been checked" : "Usage could not be refreshed"
  }

  static func activityDays(
    _ rows: [CodexDailyUsageSnapshot],
    endingAt endDate: Date,
    dayCount: Int
  ) -> [ActivityDay] {
    let calendar = activityCalendar
    let end = calendar.startOfDay(for: endDate)
    let count = min(max(dayCount, 1), 366)
    let start = calendar.date(byAdding: .day, value: -(count - 1), to: end) ?? end
    var tokensByDay: [Date: Int64] = [:]
    for row in rows {
      guard let startDate = nonempty(row.startDate),
            let date = activityDate(startDate),
            let tokens = row.tokens,
            date >= start,
            date <= end
      else { continue }
      let value = max(0, tokens)
      let current = tokensByDay[date, default: 0]
      let (sum, overflow) = current.addingReportingOverflow(value)
      tokensByDay[date] = overflow ? Int64.max : sum
    }
    return (0..<count).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
      return ActivityDay(date: date, tokens: tokensByDay[date, default: 0])
    }
  }

  static func exactTokens(_ value: Int64) -> String {
    value.formatted(.number)
  }

  static func activityWeeks(for days: [ActivityDay]) -> [[ActivityDay?]] {
    guard let first = days.first else { return [] }
    let weekday = activityCalendar.component(.weekday, from: first.date)
    var padded = Array(repeating: Optional<ActivityDay>.none, count: weekday - 1)
    padded.append(contentsOf: days.map(Optional.some))
    while !padded.count.isMultiple(of: 7) { padded.append(nil) }
    return stride(from: 0, to: padded.count, by: 7).map {
      Array(padded[$0..<$0 + 7])
    }
  }

  static func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }

  private static func formatTokens(_ value: Int64) -> String {
    value.formatted(.number.notation(.compactName))
  }

  private static func formatDays(_ value: Int64) -> String {
    "\(value) day\(value == 1 ? "" : "s")"
  }

  private static func formatDuration(_ seconds: Int64) -> String {
    Duration.seconds(seconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
  }

  private static let activityCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  private static func activityDate(_ value: String) -> Date? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
          let date = activityCalendar.date(from: DateComponents(
            calendar: activityCalendar, timeZone: activityCalendar.timeZone,
            year: year, month: month, day: day))
    else { return nil }
    let components = activityCalendar.dateComponents([.year, .month, .day], from: date)
    return components.year == year && components.month == month && components.day == day
      ? date : nil
  }
}

enum UsageActivityRange: String, CaseIterable, Identifiable {
  static let preferenceKey = "usageActivityRange"
  case week = "7 days"
  case month = "1 month"
  case year = "1 year"

  var id: Self { self }
  var dayCount: Int {
    switch self {
    case .week: 7
    case .month: 30
    case .year: 365
    }
  }
}

struct UsageActivityCalendar: View {
  let rows: [CodexDailyUsageSnapshot]
  @ObservedObject var model: AccountViewModel
  @AppStorage(UsageActivityRange.preferenceKey) private var storedRange = UsageActivityRange.year.rawValue
  @State private var selectedDate: Date?
  @State private var projects: [CodexProjectDailyActivity] = []
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var range: UsageActivityRange {
    get { UsageActivityRange(rawValue: storedRange) ?? .year }
    nonmutating set { storedRange = newValue.rawValue }
  }

  var body: some View {
    let days = UsagePresentation.activityDays(rows, endingAt: Date(), dayCount: range.dayCount)
    let maximumTokens = days.lazy.map(\.tokens).max() ?? 0
    let selectedDay = days.first { $0.date == selectedDate }
    let weeks = UsagePresentation.activityWeeks(for: days)
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Text("Daily activity").font(AIMTheme.sans(13.2, weight: .semibold))
        if let selectedDay {
          Text(selectedDay.date.formatted(date: .abbreviated, time: .omitted))
            .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
          Text("\(UsagePresentation.exactTokens(selectedDay.tokens)) tokens")
            .font(AIMTheme.mono(10, weight: .semibold))
        }
        Spacer()
        HStack(spacing: 2) {
          ForEach(UsageActivityRange.allCases) { option in
            Button {
              range = option
              if let date = selectedDate,
                 !UsagePresentation.activityDays(rows, endingAt: Date(), dayCount: option.dayCount)
                   .contains(where: { $0.date == date }) {
                selectedDate = nil
              }
            } label: {
              Text(option.rawValue)
                .font(AIMTheme.sans(9, weight: .medium))
                .foregroundStyle(range == option ? AIMTheme.activeInk : AIMTheme.muted)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(range == option ? AIMTheme.active : AIMTheme.control.opacity(0.55))
                .contentShape(Rectangle())
            }
            .buttonStyle(AIMPressButtonStyle())
            .accessibilityLabel("Show \(option.rawValue) of activity")
          }
        }
      }
      if range == .week {
        HStack(spacing: 6) {
          ForEach(days) { day in
            VStack(spacing: 5) {
              Text(day.date.formatted(.dateTime.weekday(.narrow)))
                .font(AIMTheme.sans(8, weight: .medium)).foregroundStyle(AIMTheme.faint)
              ActivityCell(
                day: day, maximumTokens: maximumTokens,
                selected: selectedDate == day.date, size: 18
              ) { selectedDate = day.date }
            }
          }
          Spacer()
        }
      } else {
        HStack(alignment: .top, spacing: 0) {
          ActivityHeatmap(weeks: weeks, maximumTokens: maximumTokens,
            selectedDate: selectedDate, size: cellSize) { selectedDate = $0 }
          Spacer(minLength: 0)
        }
      }
      if !projects.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          Text("Projects in this Codex home")
            .font(AIMTheme.sans(10, weight: .medium)).foregroundStyle(AIMTheme.muted)
            .help("Recorded from local conversation token events. These shared-home totals are separate from account usage.")
          ForEach(projects, id: \.project) { project in
            HStack(spacing: 12) {
              if project.project.hasPrefix("/") {
                AIMCopyablePath(path: project.project).font(AIMTheme.mono(9))
              } else { Text(project.project).font(AIMTheme.sans(10)) }
              Spacer()
              Text("\(UsagePresentation.exactTokens(project.tokens)) tokens")
                .font(AIMTheme.mono(9)).foregroundStyle(AIMTheme.muted)
              if !project.isComplete {
                AIMIcon(name: .info, size: 10).foregroundStyle(AIMTheme.amber)
                  .help("Some source records are incomplete. Previously recorded totals were retained.")
              }
            }
          }
        }.padding(.top, 4)
      }
    }
    .padding(.top, 14)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: range)
    .onChange(of: model.selectedAccountID) { _, _ in
      selectedDate = nil
      projects = []
    }
    .task(id: selectedDate) {
      projects = []
      guard let selectedDate else { return }
      let result = await model.projectActivity(on: selectedDate)
      guard !Task.isCancelled else { return }
      projects = result
    }
  }

  private var cellSize: CGFloat { range == .year ? 9 : 13 }
}

struct ActivityHeatmap: View {
  let weeks: [[UsagePresentation.ActivityDay?]]
  let maximumTokens: Int64
  let selectedDate: Date?
  let size: CGFloat
  let select: (Date) -> Void
  @State private var hovered = CGPoint.zero
  @State private var pointerInside = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  private var pitch: CGFloat { size + 3 }
  func day(at point: CGPoint) -> UsagePresentation.ActivityDay? {
    guard point.x >= 15, point.y >= 0 else { return nil }
    let column = Int((point.x - 15) / pitch), row = Int(point.y / pitch)
    guard weeks.indices.contains(column), (0..<7).contains(row),
      (point.x - 15).truncatingRemainder(dividingBy: pitch) < size,
      point.y.truncatingRemainder(dividingBy: pitch) < size else { return nil }
    return weeks[column][row]
  }

  func selection(after key: KeyEquivalent) -> Date? {
    let days = weeks.flatMap { $0 }.compactMap { $0 }
    guard !days.isEmpty else { return nil }
    let offset: Int
    switch key {
    case .leftArrow: offset = -7
    case .rightArrow: offset = 7
    case .upArrow: offset = -1
    case .downArrow: offset = 1
    default: return nil
    }
    let index = days.firstIndex { $0.date == selectedDate } ?? days.count - 1
    return days[min(max(index + offset, 0), days.count - 1)].date
  }

  var body: some View {
    let hoverDay = pointerInside && isEnabled ? day(at: hovered) : nil
    Canvas { context, _ in
      for row in [1, 3, 5] {
        context.draw(Text(row == 1 ? "M" : row == 3 ? "W" : "F")
          .font(AIMTheme.sans(7, weight: .medium)).foregroundStyle(AIMTheme.faint),
          at: CGPoint(x: 5, y: CGFloat(row) * pitch + size / 2))
      }
      for (column, week) in weeks.enumerated() {
        for (row, day) in week.enumerated() {
          guard let day else { continue }
          let rect = CGRect(x: 15 + CGFloat(column) * pitch, y: CGFloat(row) * pitch,
                            width: size, height: size)
          let path = Path(roundedRect: rect, cornerRadius: max(1, size * 0.18))
          let intensity = maximumTokens > 0
            ? 0.24 + 0.70 * sqrt(Double(day.tokens) / Double(maximumTokens)) : 0
          context.fill(path, with: .color(day.tokens > 0
            ? AIMTheme.green.opacity(intensity) : AIMTheme.control.opacity(0.58)))
          context.stroke(path, with: .color(selectedDate == day.date
            ? AIMTheme.ink : AIMTheme.lineSoft.opacity(0.55)), lineWidth: 1)
        }
      }
    }
    .frame(width: 15 + CGFloat(weeks.count) * pitch - 3, height: 7 * pitch - 3)
    .overlay(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: max(1, size * 0.18))
        .fill(AIMTheme.ink).frame(width: size, height: size)
        .opacity(hoverDay == nil ? 0 : 0.07)
        .animation(AIMMotion.hoverAnimation(reduceMotion: reduceMotion), value: hoverDay != nil)
        .offset(x: 15 + floor(max(0, hovered.x - 15) / pitch) * pitch,
                y: floor(max(0, hovered.y) / pitch) * pitch)
        .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      switch phase {
      case .active(let point):
        pointerInside = isEnabled && day(at: point) != nil
        if pointerInside { hovered = point }
      case .ended: pointerInside = false
      }
    }
    .gesture(SpatialTapGesture().onEnded { event in
      if isEnabled, let day = day(at: event.location) { select(day.date) }
    })
    .help(hoverDay.map {
      "\($0.date.formatted(date: .complete, time: .omitted)): \(UsagePresentation.exactTokens($0.tokens)) tokens"
    } ?? "Daily token activity. Select a day for details.")
    .focusable()
    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { event in
      guard isEnabled, let date = selection(after: event.key) else { return .ignored }
      select(date)
      return .handled
    }
    .accessibilityRepresentation {
      HStack(alignment: .top, spacing: 3) {
        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
          VStack(spacing: 3) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
              if let day {
                Button { select(day.date) } label: { Color.clear.frame(width: size, height: size) }
                  .buttonStyle(.plain)
                  .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                  .accessibilityValue("\(UsagePresentation.exactTokens(day.tokens)) tokens")
                  .accessibilityAddTraits(selectedDate == day.date ? .isSelected : [])
              } else {
                Color.clear.frame(width: size, height: size).accessibilityHidden(true)
              }
            }
          }
        }
      }.padding(.leading, 15)
    }
  }
}

private struct ActivityCell: View {
  let day: UsagePresentation.ActivityDay
  let maximumTokens: Int64
  let selected: Bool
  let size: CGFloat
  let select: () -> Void
  private var fill: Color {
    guard day.tokens > 0, maximumTokens > 0 else {
      return AIMTheme.control.opacity(0.58)
    }
    let intensity = 0.24 + 0.70 * sqrt(Double(day.tokens) / Double(maximumTokens))
    return AIMTheme.green.opacity(intensity)
  }

  var body: some View {
    Button(action: select) {
      RoundedRectangle(cornerRadius: max(1, size * 0.18))
        .fill(fill)
        .overlay {
          RoundedRectangle(cornerRadius: max(1, size * 0.18))
            .stroke(selected ? AIMTheme.ink : AIMTheme.lineSoft.opacity(0.55), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
    .help("\(day.date.formatted(date: .complete, time: .omitted)): \(UsagePresentation.exactTokens(day.tokens)) tokens")
    .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
    .accessibilityValue("\(UsagePresentation.exactTokens(day.tokens)) tokens")
  }
}

private struct AccountMenuBarUsageButton: View {
  let accountID: UUID
  @AppStorage(MenuBarUsagePreferences.defaultKey) private var defaultShowUsage = true
  @State private var showUsageOverride: Bool?

  init(accountID: UUID) {
    self.accountID = accountID
    _showUsageOverride = State(
      initialValue: MenuBarUsagePreferences.explicitValue(for: accountID))
  }

  private var showsUsage: Bool { showUsageOverride ?? defaultShowUsage }

  var body: some View {
    AIMButton(
      title: "Show in Menubar",
      icon: showsUsage ? .doubleCheck : .check
    ) {
      let value = !showsUsage
      MenuBarUsagePreferences.setOverride(value, for: accountID)
      showUsageOverride = value
    }
    .accessibilityLabel("Show in Menubar")
    .help(showsUsage ? "Hide this account's usage in Menubar" : "Show this account's usage in Menubar")
    .accessibilityValue(showsUsage ? "On" : "Off")
    .accessibilityAddTraits(showsUsage ? .isSelected : [])
    .contextMenu {
      Button("Use Settings default") {
        MenuBarUsagePreferences.useDefault(for: accountID)
        showUsageOverride = nil
      }.disabled(showUsageOverride == nil)
    }
    .onAppear {
      showUsageOverride = MenuBarUsagePreferences.explicitValue(for: accountID)
    }
  }
}

private struct AccountUsagePanel: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel

  private var snapshot: CodexAccountUsageSnapshot? { model.usage(for: account.id) }
  private var cached: CachedCodexAccountUsage? { model.cachedUsage(for: account.id) }
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
      if UsagePresentation.hasContent(bucket) {
        seen.insert(key)
        result.append((key, bucket))
      }
    }
    for (key, bucket) in limits.buckets.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
      let identity = bucket.id ?? key
      guard seen.insert(identity).inserted else { continue }
      if UsagePresentation.hasContent(bucket) { result.append((key, bucket)) }
    }
    return result
  }

  var body: some View {
    AIMPanel(title: "Usage", importance: .primary) {
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

            let accountFacts = UsagePresentation.accountFacts(snapshot)
            let summaryFacts = UsagePresentation.summaryFacts(snapshot.usage)
            if !accountFacts.isEmpty || !summaryFacts.isEmpty {
              HStack(alignment: .top, spacing: 12) {
                ForEach(accountFacts) { fact in
                  UsageFact(label: fact.label, value: fact.value)
                }
                Spacer(minLength: 12)
                ForEach(summaryFacts) { fact in
                  UsageFact(label: fact.label, value: fact.value)
                }
              }
              .padding(.bottom, 14)
            }

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

            if !limitBuckets.contains(where: { UsagePresentation.hasRateLimits($0.value) }) {
              UsageUnavailableRow(text: "Rate limits unavailable")
            }

            if !model.dailyUsage(for: account.id).isEmpty {
              UsageActivityCalendar(rows: model.dailyUsage(for: account.id), model: model)
            }
          }
          .padding(16)
        } else {
          HStack(spacing: 12) {
            AIMIcon(name: .info, size: 15).foregroundStyle(AIMTheme.muted)
            VStack(alignment: .leading, spacing: 3) {
              Text(UsagePresentation.emptyUsageTitle(
                failure: usageFailure, needsSignIn: account.verification.state == .needsSignIn))
                .font(AIMTheme.sans(12, weight: .semibold))
              if let failure = usageFailure {
                Text(failure).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.amber)
              } else {
                Text("Refresh this saved account without changing the default account.")
                  .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
              }
            }
            Spacer()
            if let failure = usageFailure {
              WarningCopyButton(label: "Copy usage error") { model.copyWarnings([failure]) }
            }
            refreshButton
          }
          .padding(16)
          if !model.dailyUsage(for: account.id).isEmpty {
            UsageActivityCalendar(rows: model.dailyUsage(for: account.id), model: model)
              .padding(.horizontal, 16).padding(.bottom, 16)
          }
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
      refreshButton
    }
  }

  private var refreshButton: some View {
    AIMIconButton(
      icon: .refresh,
      label: isRefreshing ? "Refreshing usage" : "Refresh usage",
      disabled: model.usageRefreshAccountID != nil || model.isBusy
    ) {
      Task { await model.refreshUsage(accountID: account.id) }
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
        if let plan = UsagePresentation.nonempty(bucket.plan) {
          Text(plan.capitalized)
            .font(AIMTheme.sans(9, weight: .medium)).foregroundStyle(AIMTheme.muted)
        }
      }
      if UsagePresentation.hasWindow(bucket.primary) || UsagePresentation.hasWindow(bucket.secondary) {
        HStack(spacing: 20) {
          if let primary = bucket.primary, UsagePresentation.hasWindow(primary) {
            UsageMeter(title: windowLabel(primary, "Current window"), window: primary)
          }
          if let secondary = bucket.secondary, UsagePresentation.hasWindow(secondary) {
            UsageMeter(title: windowLabel(secondary, "Secondary window"), window: secondary)
          }
        }
      }
      let credits = UsagePresentation.credits(bucket.credits)
      let spendControl = UsagePresentation.spendControl(bucket.spendControlReached)
      if credits != nil || spendControl != nil {
        HStack(spacing: 20) {
          if let credits { UsageFact(label: "Credits", value: credits) }
          if let spendControl { UsageFact(label: "Spend control", value: spendControl) }
          Spacer()
        }
      }
    }
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
  let window: CodexRateLimitWindowSnapshot
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var used: Int { min(max(window.usedPercent ?? 0, 0), 100) }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(AIMTheme.sans(11, weight: .medium))
        Spacer()
        Text("\(used)% used")
          .font(AIMTheme.mono(10, weight: .semibold))
      }
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Rectangle().fill(AIMTheme.control)
          Rectangle()
            .fill(used >= 90 ? AIMTheme.red : (used >= 70 ? AIMTheme.amber : AIMTheme.blue))
            .frame(width: geometry.size.width * CGFloat(used) / 100)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
      }
      .frame(height: 5)
      if let reset = window.resetsAt {
        Text("Resets \(reset.formatted(.relative(presentation: .named)))")
          .font(AIMTheme.sans(9)).foregroundStyle(AIMTheme.muted)
      }
    }
    .frame(maxWidth: .infinity)
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: used)
  }

}

private struct UsageFact: View {
  let label: String
  let value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(AIMTheme.sans(9)).foregroundStyle(AIMTheme.muted)
      Text(value).font(AIMTheme.sans(11, weight: .medium)).monospacedDigit()
    }
  }
}

private struct DetailRow: View {
  let label: String, value: String
  var zebra = false
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(label).font(AIMTheme.sans(11, weight: .medium)).frame(width: 118, alignment: .leading)
      Group {
        if value.hasPrefix("/") || value.hasPrefix("~/") {
          AIMCopyablePath(path: value)
        } else {
          Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(value)
        }
      }.font(AIMTheme.mono(10)).foregroundStyle(AIMTheme.muted)
      Spacer()
    }.padding(.horizontal, 16).frame(minHeight: 40).background(
      zebra ? AIMTheme.panel2.opacity(0.55) : .clear)
  }
}

private struct CleanupPage: View {
  @ObservedObject var model: AccountViewModel
  @State private var sizes = RebuildableCacheSizes(usageBytes: 0, conversationBytes: 0)
  @State private var conversations: [CleanupConversation] = []
  @State private var samples: [CleanupUsageSample] = []
  @State private var trash: [ConversationCleanupBatch] = []
  @State private var selectedConversations: Set<String> = []
  @State private var selectedSamples: Set<Int64> = []
  @State private var clearIndex = false
  @State private var range: CleanupDateRange = .olderMonth
  @State private var choosingRange = false
  @State private var from = Date().addingTimeInterval(-30 * 86_400)
  @State private var through = Date()
  @State private var anchor = Date()
  @State private var loading = false
  @State private var error: String?
  @State private var review: CleanupReview?
  @State private var confirming = false
  @State private var removingBatch: ConversationCleanupBatch?
  private var unavailable: Bool { loading || model.isBusy }
  private var visibleConversations: [CleanupConversation] {
    conversations.filter { range.contains($0.updatedAt, now: anchor, from: from, through: through) }
  }
  private var visibleSamples: [CleanupUsageSample] {
    samples.filter { range.contains($0.fetchedAt, now: anchor, from: from, through: through) }
  }

  var body: some View {
    AIMScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          CleanupRangeSelect(selection: $range, expanded: $choosingRange).disabled(unavailable)
          if range == .custom {
            DatePicker("From", selection: $from, displayedComponents: .date)
            DatePicker("Through", selection: $through, in: from..., displayedComponents: .date)
          }
          Spacer(minLength: 0)
          if loading { ProgressView().controlSize(.small) }
          AIMButton(title: "Reload", icon: .refresh, disabled: unavailable) { Task { await reload() } }
        }
        AIMPanel(title: "Conversations", importance: .primary, headerAccessories: AnyView(
          Text("\(visibleConversations.count.formatted()) conversations · Shared · Codex CLI")
            .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted))) {
          VStack(alignment: .leading, spacing: 12) {
            if visibleConversations.isEmpty {
              HStack {
                Text("No conversations match this time range.").foregroundStyle(AIMTheme.muted)
                Spacer()
                if range != .all {
                  AIMButton(title: "Show all") { range = .all }
                }
              }
            } else {
              Text("Choose projects or conversations. Dates use their last update.")
                .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
              if visibleConversations.contains(where: { !$0.archived }) {
                conversationTree(archived: false)
              }
              if visibleConversations.contains(where: \.archived) {
                conversationTree(archived: true)
              }
            }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading).disabled(unavailable)
        }
        AIMPanel(title: "Cached data", headerAccessories: AnyView(
          Text("\(visibleSamples.count.formatted()) samples")
            .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted))) {
          VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("Usage history by account") {
              let grouped = Dictionary(grouping: visibleSamples, by: \.accountID)
              VStack(alignment: .leading, spacing: 8) {
                ForEach(grouped.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { accountID in
                  let entries = grouped[accountID] ?? []
                  let name = model.status?.accounts.first { $0.id == accountID }?.identity.email ?? accountID.uuidString
                  Toggle("\(name) · \(entries.count.formatted()) samples · \(sizeText(entries.reduce(0) { $0 + $1.bytes }))", isOn: Binding(
                    get: { entries.allSatisfy { selectedSamples.contains($0.id) } },
                    set: { enabled in
                      let ids = Set(entries.map(\.id))
                      if enabled { selectedSamples.formUnion(ids) } else { selectedSamples.subtract(ids) }
                      review = nil
                    })).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                }
                if visibleSamples.isEmpty { Text("No cached samples in this date range.").foregroundStyle(AIMTheme.muted) }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Shared conversation index · \(sizeText(sizes.conversationBytes))", isOn: $clearIndex)
              .toggleStyle(.checkbox).disabled(range != .all || sizes.conversationBytes == 0)
              .help("Choose All time to clear search metadata. This index rebuilds when Chat History opens.")
            Text("Caches rebuild when needed. Daily activity stays saved.")
              .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
          }.padding(16).disabled(unavailable)
        }
        let protectedCount = conversations.filter { $0.exclusionReason != nil }.count
        if protectedCount > 0 {
          HStack(spacing: 6) {
            AIMIcon(name: .info, size: 12)
            Text("\(protectedCount.formatted()) shared or unsafe files are protected.")
          }.font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
            .help("Linked or foreign-owned files cannot be removed. Other conversations remain selectable.")
        }
        HStack {
          Text("Selected").font(AIMTheme.sans(11, weight: .medium))
          Text(selectedConversations.isEmpty && selectedSamples.isEmpty && !clearIndex
            ? "Choose items to review."
            : "\(selectedConversations.count.formatted()) conversations · \(selectedSamples.count.formatted()) samples\(clearIndex ? " · index" : "")")
            .font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
          Spacer()
          AIMButton(title: "Review selection", tone: .primary,
            disabled: unavailable || (selectedConversations.isEmpty && selectedSamples.isEmpty && !clearIndex)) {
              Task { await makeReview() }
            }
        }.padding(12).background(AIMTheme.panel2)
          .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
        if let review {
          AIMPanel(title: "Review before cleanup", importance: .primary) {
            VStack(alignment: .leading, spacing: 10) {
              Text("\(review.plan?.conversations.count ?? 0) conversations · \(sizeText(review.plan?.bytes ?? 0)) to recoverable trash")
              Text("\(review.samples.count) cache samples · \(sizeText(review.samples.reduce(0) { $0 + $1.bytes })) of cached payloads")
              if review.clearIndex { Text("Clear the shared conversation index (\(sizeText(sizes.conversationBytes)))") }
              Text("\(range.rawValue). Moving conversations does not free disk space. Cached payload bytes exclude database overhead.")
                .foregroundStyle(AIMTheme.muted)
              if let plan = review.plan {
                DisclosureGroup("Selected conversations") {
                  AIMVirtualList(items: plan.conversations, fixedRowHeight: 32) { item in
                    AnyView(HStack {
                      AIMCopyablePath(path: item.relativePath).help(item.title)
                      Spacer()
                      Text(sizeText(item.bytes)).foregroundStyle(AIMTheme.muted)
                    }.font(AIMTheme.sans(10)).padding(.horizontal, 4))
                  }.frame(height: min(CGFloat(plan.conversations.count) * 32, 192))
                }
              }
              if !review.samples.isEmpty {
                DisclosureGroup("Selected cache samples") {
                  AIMVirtualList(items: review.samples, fixedRowHeight: 30) { sample in
                    AnyView(HStack {
                      Text(model.status?.accounts.first { $0.id == sample.accountID }?.identity.email ?? sample.accountID.uuidString)
                        .lineLimit(1)
                      Spacer()
                      Text(sample.fetchedAt.formatted()).foregroundStyle(AIMTheme.muted)
                    }.font(AIMTheme.sans(10)).padding(.horizontal, 4))
                  }.frame(height: min(CGFloat(review.samples.count) * 30, 180))
                }
              }
              HStack {
                AIMButton(title: "Cancel") { self.review = nil }
                Spacer()
                AIMButton(title: "Confirm cleanup", tone: .primary, disabled: unavailable) { confirming = true }
              }
            }.padding(16)
          }
        }
        if !trash.isEmpty {
          AIMPanel(title: "Recoverable conversation trash") {
            VStack(spacing: 0) {
              ForEach(trash) { batch in
                HStack(spacing: 10) {
                  VStack(alignment: .leading, spacing: 3) {
                    Text("\(batch.conversations.count.formatted()) conversations · \(sizeText(batch.bytes))")
                    Text(batch.createdAt.formatted()).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
                  }
                  Spacer()
                  AIMButton(title: "Restore", disabled: unavailable) { Task { await restore(batch) } }
                  AIMButton(title: "Remove permanently", disabled: unavailable) { removingBatch = batch }
                }.padding(12)
              }
            }
          }
        }
        Text("Account access, settings, backups, and saved activity stay unchanged.")
          .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
        if let error { Notice(text: error, tone: AIMTheme.amber) }
        if let notice = model.notice { Notice(text: notice, tone: AIMTheme.blue) }
      }
      .font(AIMTheme.sans(11))
      .frame(maxWidth: .infinity, minHeight: 620, alignment: .topLeading)
      .overlayPreferenceValue(CleanupRangeAnchor.self) { anchor in
        if choosingRange, let anchor {
          GeometryReader { geometry in
            let bounds = geometry[anchor]
            ZStack(alignment: .topLeading) {
              Color.clear.contentShape(Rectangle()).onTapGesture { choosingRange = false }
              CleanupRangeOptions(selection: $range, expanded: $choosingRange)
                .frame(width: bounds.width).offset(x: bounds.minX, y: bounds.maxY + 3)
            }
          }
        }
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.top, 12)
    .padding(.bottom, 12)
    .task { await reload() }
    .onChange(of: range) { _, _ in resetSelection() }
    .onChange(of: from) { _, _ in resetSelection() }
    .onChange(of: through) { _, _ in resetSelection() }
    .onChange(of: clearIndex) { _, _ in review = nil }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in choosingRange = false }
    .alert("Apply reviewed cleanup?", isPresented: $confirming) {
      Button("Cancel", role: .cancel) {}
      Button("Apply cleanup") { Task { await apply() } }
    } message: { Text("Selected conversations move to recoverable trash. Selected cache records are cleared. Daily activity totals remain saved.") }
    .alert("Permanently remove conversation trash?", isPresented: Binding(
      get: { removingBatch != nil }, set: { if !$0 { removingBatch = nil } }), presenting: removingBatch) { batch in
      Button("Cancel", role: .cancel) { removingBatch = nil }
      Button("Remove permanently", role: .destructive) {
        Task { await remove(batch) }
      }
    } message: { batch in Text("\(batch.conversations.count) conversations will be removed from trash. This cannot be undone.") }
  }

  private func conversationTree(archived: Bool) -> some View {
    let entries = visibleConversations.filter { $0.archived == archived }
    let grouped = Dictionary(grouping: entries, by: \.project)
    return DisclosureGroup(archived ? "Archived conversations (\(entries.count.formatted()))" : "Active conversations (\(entries.count.formatted()))") {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(grouped.keys.sorted(), id: \.self) { project in
          let projectEntries = grouped[project] ?? []
          let selectable = projectEntries.filter { $0.exclusionReason == nil }
          DisclosureGroup {
            AIMVirtualList(items: projectEntries, fixedRowHeight: 34) { item in
              AnyView(HStack(spacing: 8) {
                Toggle(item.title, isOn: Binding(
                  get: { selectedConversations.contains(item.id) },
                  set: { enabled in
                    if enabled { selectedConversations.insert(item.id) } else { selectedConversations.remove(item.id) }
                    review = nil
                  })).toggleStyle(.checkbox).lineLimit(1)
                  .disabled(item.exclusionReason != nil).help(item.exclusionReason ?? item.relativePath)
                Spacer(minLength: 4)
                Text(item.updatedAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(AIMTheme.muted)
                Text(sizeText(item.bytes)).foregroundStyle(AIMTheme.muted).frame(width: 65, alignment: .trailing)
              }.padding(.horizontal, 4).font(AIMTheme.sans(10)))
            }.frame(height: min(CGFloat(projectEntries.count) * 34, 204))
          } label: {
            Toggle("\(URL(fileURLWithPath: project).lastPathComponent) (\(projectEntries.count.formatted()))", isOn: Binding(
              get: { !selectable.isEmpty && selectable.allSatisfy { selectedConversations.contains($0.id) } },
              set: { enabled in
                let ids = Set(selectable.map(\.id))
                if enabled { selectedConversations.formUnion(ids) } else { selectedConversations.subtract(ids) }
                review = nil
              })).toggleStyle(.checkbox).disabled(selectable.isEmpty).help(project)
                .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if entries.isEmpty { Text("No conversations in this date range.").foregroundStyle(AIMTheme.muted) }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func resetSelection() {
    selectedConversations = []
    selectedSamples = []
    clearIndex = false
    review = nil
  }
  private func reload() async {
    loading = true
    defer { loading = false }
    error = nil
    do {
      let data = try await model.cleanupData()
      conversations = data.conversations
      samples = data.samples
      trash = data.trash
      sizes = await model.rebuildableCacheSizes()
      anchor = Date()
      resetSelection()
    } catch { self.error = error.localizedDescription }
  }
  private func makeReview() async {
    loading = true
    defer { loading = false }
    error = nil
    do {
      let selected = visibleConversations.filter { selectedConversations.contains($0.id) }
      let plan = selected.isEmpty ? nil : try await model.reviewConversationCleanup(selected)
      review = CleanupReview(plan: plan, samples: visibleSamples.filter { selectedSamples.contains($0.id) }, clearIndex: clearIndex)
    } catch { self.error = error.localizedDescription }
  }
  private func apply() async {
    guard let review else { return }
    do {
      try await model.applyCleanup(review.plan, samples: review.samples, clearIndex: review.clearIndex)
      self.review = nil
      await reload()
    } catch {
      self.review = nil
      await reload()
      self.error = "\(error.localizedDescription) Review again. Files already in trash can be restored."
    }
  }
  private func restore(_ batch: ConversationCleanupBatch) async {
    do { try await model.restoreCleanup(batch.id); await reload() }
    catch { self.error = error.localizedDescription }
  }
  private func remove(_ batch: ConversationCleanupBatch) async {
    removingBatch = nil
    do { try await model.emptyCleanup(batch.id); await reload() }
    catch { self.error = error.localizedDescription }
  }

  private func sizeText(_ bytes: Int64) -> String {
    bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

private struct CleanupReview {
  let plan: ConversationCleanupPlan?
  let samples: [CleanupUsageSample]
  let clearIndex: Bool
}

struct CleanupRangeSelect: View {
  @Binding var selection: CleanupDateRange
  @Binding var expanded: Bool
  @FocusState private var triggerFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Text("Time range").font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
      Button { expanded.toggle() } label: {
        HStack(spacing: 12) {
          Text(selection.rawValue).lineLimit(1)
          Spacer(minLength: 0)
          AIMIcon(name: .chevron, size: 10).rotationEffect(.degrees(expanded ? -90 : 90))
            .foregroundStyle(AIMTheme.muted)
        }
        .font(AIMTheme.sans(11, weight: .medium)).foregroundStyle(AIMTheme.ink)
        .padding(.horizontal, 10).frame(width: 184, height: 28)
        .background(AIMTheme.control).clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: AIMTheme.radius)
          .stroke(expanded || triggerFocused ? AIMTheme.blue : AIMTheme.line, lineWidth: 1))
      }
      .buttonStyle(AIMPressButtonStyle()).focused($triggerFocused)
      .accessibilityLabel("Time range").accessibilityValue(selection.rawValue)
      .accessibilityHint(expanded ? "Close time ranges" : "Choose a time range")
      .accessibilityIdentifier("cleanup-time-range")
      .anchorPreference(key: CleanupRangeAnchor.self, value: .bounds) { $0 }
      .onChange(of: expanded) { _, open in if !open { triggerFocused = true } }
    }
  }
}

private struct CleanupRangeAnchor: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

private struct CleanupRangeOptions: View {
  @Binding var selection: CleanupDateRange
  @Binding var expanded: Bool
  @FocusState private var focusedOption: CleanupDateRange?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(CleanupDateRange.allCases) { option in
        Button { choose(option) } label: {
          HStack(spacing: 7) {
            AIMIcon(name: .check, size: 10).opacity(option == selection ? 1 : 0)
            Text(option.rawValue)
            Spacer(minLength: 0)
          }
          .font(AIMTheme.sans(11, weight: option == selection ? .medium : .regular))
          .foregroundStyle(AIMTheme.ink).padding(.horizontal, 8).frame(height: 24)
          .background(option == focusedOption ? AIMTheme.listSelection : .clear)
          .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
        }
        .buttonStyle(AIMPressButtonStyle()).focused($focusedOption, equals: option)
        .accessibilityAddTraits(option == selection ? .isSelected : [])
        if option == .month || option == .olderYear {
          Rectangle().fill(AIMTheme.lineSoft).frame(height: 1).padding(.vertical, 3)
        }
      }
    }
    .padding(4).background(AIMTheme.rail)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
    .overlay(RoundedRectangle(cornerRadius: AIMTheme.radius).stroke(AIMTheme.line, lineWidth: 1))
    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    .onAppear { focusedOption = selection }
    .onKeyPress(.upArrow) { focusedOption = (focusedOption ?? selection).moved(.up); return .handled }
    .onKeyPress(.downArrow) { focusedOption = (focusedOption ?? selection).moved(.down); return .handled }
    .onKeyPress(.return) { choose(focusedOption ?? selection); return .handled }
    .onExitCommand { expanded = false }
    .accessibilityLabel("Time ranges")
  }

  private func choose(_ option: CleanupDateRange) {
    selection = option
    expanded = false
  }
}

enum CleanupDateRange: String, CaseIterable, Identifiable {
  case hour = "Last hour", day = "Last 24 hours", week = "Last 7 days", month = "Last 4 weeks"
  case olderWeek = "Older than 7 days", olderMonth = "Older than 30 days", olderYear = "Older than 1 year"
  case all = "All time", custom = "Custom dates"
  var id: String { rawValue }
  func moved(_ direction: MoveCommandDirection) -> Self? {
    guard direction == .up || direction == .down, let index = Self.allCases.firstIndex(of: self) else { return nil }
    return Self.allCases[min(max(index + (direction == .up ? -1 : 1), 0), Self.allCases.count - 1)]
  }
  func contains(_ date: Date, now: Date, from: Date, through: Date) -> Bool {
    if self == .all { return true }
    if self == .custom {
      let start = Calendar.current.startOfDay(for: from)
      let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: through)) ?? through
      return start <= date && date < end
    }
    let seconds: TimeInterval
    switch self {
    case .hour: seconds = 3_600
    case .day: seconds = 86_400
    case .week, .olderWeek: seconds = 7 * 86_400
    case .month: seconds = 28 * 86_400
    case .olderMonth: seconds = 30 * 86_400
    case .olderYear: seconds = 365 * 86_400
    case .all, .custom: return false
    }
    let cutoff = now.addingTimeInterval(-seconds)
    return [.olderWeek, .olderMonth, .olderYear].contains(self) ? date < cutoff : cutoff <= date && date <= now
  }
}

private struct SettingsPage: View {
  @ObservedObject var model: AccountViewModel
  @Binding var showFocusIndicators: Bool
  @AppStorage(AIManagerWindowBehavior.minimizeToTrayKey) private var minimizeToTray = false
  @AppStorage(MenuBarUsagePreferences.defaultKey) private var defaultShowUsage = true
  @AppStorage(AIMTranslucency.preferenceKey) private var translucency = AIMTranslucency.initialValue
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    AIMScrollView {
      VStack(spacing: 8) {
        AIMPanel(title: "App behavior") {
          VStack(spacing: 0) {
            settingRow(isOn: $minimizeToTray, title: "Minimize to Menubar") {
              Text("Hide the window and keep Switch available from its menu-bar icon.")
            }
            settingRow(isOn: $showFocusIndicators, title: "Keyboard focus indicators", zebra: true) {
              Text("Show outlines only while keyboard controls have focus.")
            }
            HStack(spacing: 16) {
              VStack(alignment: .leading, spacing: 2) {
                Text("Body translucency").font(AIMTheme.sans(11, weight: .medium))
                Text("Keep content readable while revealing a little of the desktop.")
                  .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
              }
              Spacer(minLength: 24)
              Slider(value: $translucency, in: 0...50, step: 1)
                .frame(width: 160).accessibilityLabel("Body translucency")
              Text("\(Int(translucency))%")
                .font(AIMTheme.mono(10)).frame(width: 32, alignment: .trailing)
            }.padding(.horizontal, 16).frame(minHeight: 48)
          }
        }
        AIMPanel(title: "Menubar defaults") {
          settingRow(isOn: $defaultShowUsage, title: "Show account usage") {
            Text("Accounts without their own choice show cached usage in Menubar.")
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
        AIMPanel(title: "Data locations") {
          VStack(spacing: 0) {
            DataLocationRow(
              title: "Codex home",
              detail: "Settings, plugins, conversations, and databases stay here when accounts change.",
              path: model.paths.defaultHome.path
            ) {
              model.showDataLocation(model.paths.defaultHome, name: "Codex home")
            }
            DataLocationRow(
              title: "Saved account vault",
              detail: "Switch keeps one private auth.json snapshot per saved account.",
              path: model.paths.credentialStore.path,
              zebra: true
            ) {
              model.showDataLocation(model.paths.credentialStore, name: "Saved account vault")
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

private struct DataLocationRow: View {
  let title: String
  let detail: String
  let path: String
  var zebra = false
  let reveal: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(AIMTheme.sans(11, weight: .semibold))
        Text(detail).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
        AIMCopyablePath(path: path).font(AIMTheme.mono(9)).foregroundStyle(AIMTheme.faint)
      }
      Spacer(minLength: 20)
      AIMButton(title: "Reveal", icon: .folder, action: reveal)
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    .background(zebra ? AIMTheme.panel2.opacity(0.55) : .clear)
  }
}

enum HistoryHeaderLayout {
  static let height: CGFloat = 40
  static let countWidth: CGFloat = 128
  static let warningWidth: CGFloat = 32
  static let statusWidth: CGFloat = 20
}

private struct HistoryPage: View {
  @ObservedObject var model: AccountViewModel
  @State private var threadQuery = ""

  var body: some View {
    HStack(spacing: 8) {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          Text("Conversations").font(AIMTheme.sans(12, weight: .semibold))
          Spacer(minLength: 8)
          Text(historyCountText)
            .font(AIMTheme.sans(9))
            .foregroundStyle(AIMTheme.muted)
            .monospacedDigit()
            .contentTransition(.numericText())
            .frame(
              width: HistoryHeaderLayout.countWidth,
              height: HistoryHeaderLayout.height,
              alignment: .trailing)
          Group {
            if model.chatHistory.skippedFileCount > 0 || model.chatHistory.unreadableRecordCount > 0 {
              WarningCopyButton(label: "Copy history warning") {
                model.copyWarnings([historyIssueText])
              }
              .help(historyIssueText)
            } else {
              Color.clear
            }
          }
          .frame(width: HistoryHeaderLayout.warningWidth, height: HistoryHeaderLayout.height)
          Group {
            if let error = model.chatHistoryError {
              Circle().fill(AIMTheme.red).frame(width: 6, height: 6)
                .help(error)
                .accessibilityLabel(error)
            } else if model.isChatHistoryLoading {
              ProgressView().controlSize(.small)
            } else {
              Color.clear
            }
          }
          .frame(width: HistoryHeaderLayout.statusWidth, height: HistoryHeaderLayout.height)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: HistoryHeaderLayout.height)
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
    .task { await model.refreshChatHistory(query: threadQuery) }
    .task(id: threadQuery) { await model.searchChatHistory(query: threadQuery) }
  }

  private var historyCountText: String {
    let result = model.chatHistory
    if threadQuery.isEmpty { return "\(result.totalThreadCount.formatted()) conversations" }
    return "\(result.matchingThreadCount.formatted()) of \(result.totalThreadCount.formatted()) conversations"
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
      .background {
        AIMHoverBackground(base: selected ? AIMTheme.listSelection : striped ? AIMTheme.listStripe : .clear,
          highlight: AIMTheme.listHover, hovered: hovered && !selected)
      }
      .overlay(alignment: .leading) {
        if selected { Rectangle().fill(AIMTheme.active).frame(width: 3) }
      }
      .foregroundStyle(AIMTheme.ink)
    }
    .buttonStyle(AIMPressButtonStyle())
    .onHover { hovered = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: selected)
    .accessibilityLabel("\(thread.title), \(projectLabel)")
  }

  private var projectLabel: String {
    guard let directory = thread.workingDirectory else { return "Codex" }
    let name = URL(fileURLWithPath: directory).lastPathComponent
    return name.isEmpty ? "Codex" : name
  }
}

enum ChatFilterPersistence {
  static let defaultsKey = "chat.messageFilterMask"

  static func load(from defaults: UserDefaults = .standard) -> ChatMessageFilter {
    guard defaults.object(forKey: defaultsKey) != nil else { return .all }
    return normalized(defaults.integer(forKey: defaultsKey))
  }

  static func save(_ filter: ChatMessageFilter, to defaults: UserDefaults = .standard) {
    defaults.set(normalized(filter.rawValue).rawValue, forKey: defaultsKey)
  }

  static func normalized(_ rawValue: Int) -> ChatMessageFilter {
    ChatMessageFilter(rawValue: rawValue & ChatMessageFilter.all.rawValue)
  }
}

private struct ChatDetailPane: View {
  @ObservedObject var model: AccountViewModel
  @State private var messageQuery = ""
  @State private var messageFilter: ChatMessageFilter
  @State private var isSearching = false
  @State private var presentations: [String: ChatMessagePresentation] = [:]
  @State private var presentationRevision = 0

  init(model: AccountViewModel) {
    self.model = model
    _messageFilter = State(initialValue: ChatFilterPersistence.load())
  }

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
          HStack(spacing: 6) {
            Text("\(thread.messageCount.formatted()) messages")
            if let tokens = thread.totalTokens {
              Text("·")
              Text("\(tokens.formatted(.number.notation(.compactName))) tokens")
                .help("\(tokens.formatted()) recorded tokens")
            }
          }
          .font(AIMTheme.sans(9.5))
          .foregroundStyle(AIMTheme.muted)
          .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(AIMTheme.panel2)
      } else {
        Color.clear.frame(height: 58).background(AIMTheme.panel2)
      }

      VStack(spacing: 0) {
        HStack(spacing: 10) {
          HistorySearchField(text: $messageQuery, placeholder: "Search this chat")
          if isSearching {
            ProgressView().controlSize(.small).frame(width: 24, height: 24)
          } else if let detail = model.selectedChat, messageFilter != .all || !messageQuery.isEmpty {
            Text(messageCountText(detail))
              .font(AIMTheme.sans(9.5))
              .foregroundStyle(AIMTheme.muted)
              .contentTransition(.numericText())
          }
          if let detail = model.selectedChat {
            ChatFilteredCopyButton(messages: displayedMessages(detail))
          }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)

        HStack(spacing: 6) {
          Text("Show")
            .font(AIMTheme.sans(9.5, weight: .medium))
            .foregroundStyle(AIMTheme.muted)
          ForEach(ChatFilterChoice.allCases) { choice in
            ChatFilterButton(
              choice: choice,
              selected: messageFilter.contains(choice.filter)) {
                toggleFilter(choice.filter)
              }
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .overlay(alignment: .top) { Rectangle().fill(AIMTheme.lineSoft).frame(height: 1) }
      }
      .background(AIMTheme.panel)

      if model.isChatLoading {
        VStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Opening chat").font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let detail = model.selectedChat {
        AIMVirtualList(
          items: detailItems(detail), rowSpacing: 0,
          contentRevision: presentationRevision,
          onReachEnd: { Task { await model.loadMoreChatMessages() } }
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
    .onChange(of: messageFilter.rawValue) { _, _ in
      ChatFilterPersistence.save(messageFilter)
    }
  }

  private var selectedSummary: ChatThreadSummary? {
    model.selectedChat?.thread
      ?? model.chatHistory.threads.first { $0.id == model.selectedChatID }
  }

  private var searchKey: ChatMessageSearchKey {
    ChatMessageSearchKey(
      threadID: model.selectedChatID,
      query: messageQuery,
      filterMask: messageFilter.rawValue,
      fileByteCount: model.selectedChat?.thread.fileByteCount ?? 0)
  }

  private var presentationKey: ChatPresentationKey {
    ChatPresentationKey(
      threadID: model.selectedChatID,
      fileByteCount: model.selectedChat?.thread.fileByteCount ?? 0,
      messageIDs: model.selectedChat?.messages.map(\.id) ?? [])
  }

  private func displayedMessages(_ detail: ChatThreadDetail) -> [ChatMessage] {
    filteredMessages(detail.messages)
  }

  private func filteredMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
    messages.filter { messageFilter.includes($0.role) }
  }

  private func toggleFilter(_ filter: ChatMessageFilter) {
    if messageFilter.contains(filter) {
      messageFilter.remove(filter)
    } else {
      messageFilter.insert(filter)
    }
  }

  private func detailItems(_ detail: ChatThreadDetail) -> [ChatDetailListItem] {
    var items: [ChatDetailListItem] = []
    let messages = displayedMessages(detail)
    if messages.isEmpty && !isSearching {
      let hasQuery = !messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      items.append(.empty(hasQuery ? "No matching messages" : "No messages in this filter"))
    } else {
      items.append(contentsOf: messages.enumerated().map { index, message in
        .message(
          message,
          separated: index == 0 || messages[index - 1].role != message.role)
      })
    }
    if detail.nextOffset != nil { items.append(.loadMore) }
    items.append(.bottomSpace)
    return items
  }

  @ViewBuilder
  private func detailRow(_ item: ChatDetailListItem) -> some View {
    switch item {
    case let .message(message, separated):
      ChatMessageRow(
        message: message,
        presentation: presentations[message.id],
        fallbackText: model.renderedChatMessages[message.id] ?? AttributedString(message.text),
        separated: separated)
    case let .empty(text):
      VStack(spacing: 6) {
        AIMIcon(name: .search, size: 16).foregroundStyle(AIMTheme.muted)
        Text(text).font(AIMTheme.sans(10, weight: .medium))
      }
      .frame(maxWidth: .infinity, minHeight: 120)
      .padding(.horizontal, 12)
    case .bottomSpace:
      Color.clear.frame(height: 8)
    case .loadMore:
      HStack(spacing: 6) {
        if model.isChatPageLoading { ProgressView().controlSize(.mini) }
        AIMButton(title: model.isChatPageLoading ? "Loading messages" : "Load more messages",
          disabled: model.isChatPageLoading) { Task { await model.loadMoreChatMessages() } }
      }
      .frame(maxWidth: .infinity, minHeight: 32)
    }
  }

  private func messageCountText(_ detail: ChatThreadDetail) -> String {
    if messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let count = detail.matchingMessageCount
      return messageFilter == .all
        ? "\(count.formatted()) messages"
        : "\(count.formatted()) shown"
    }
    return "\(detail.matchingMessageCount.formatted()) matches"
  }

  private func threadContext(_ thread: ChatThreadSummary) -> String {
    var parts: [String] = []
    if let directory = thread.workingDirectory {
      let project = URL(fileURLWithPath: directory).lastPathComponent
      if !project.isEmpty { parts.append(project) }
    }
    parts.append(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
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
      let rendered = try await ChatMessagePresenter.render(messages: detail.messages.filter { presentations[$0.id] == nil })
      guard !Task.isCancelled,
        model.selectedChatID == detail.thread.id,
        model.selectedChat?.thread.fileByteCount == detail.thread.fileByteCount
      else { return }
      let ids = Set(detail.messages.map(\.id))
      presentations = presentations.filter { ids.contains($0.key) }
      presentations.merge(rendered) { _, new in new }
      presentationRevision &+= 1
    } catch is CancellationError {
      return
    } catch {
      presentations = [:]
    }
  }

  @MainActor
  private func updateMessageSearch() async {
    guard model.selectedChat != nil else {
      isSearching = false
      return
    }
    isSearching = true
    do {
      try await Task.sleep(for: .milliseconds(120))
      await model.searchChatMessages(query: messageQuery, filter: messageFilter)
      guard !Task.isCancelled else { return }
      isSearching = false
    } catch is CancellationError {
      return
    } catch {
      isSearching = false
    }
  }
}

private enum ChatDetailListItem: Identifiable, Equatable {
  case message(ChatMessage, separated: Bool)
  case empty(String)
  case bottomSpace
  case loadMore

  var id: String {
    switch self {
    case let .message(message, _): "message:\(message.id)"
    case let .empty(text): "empty:\(text)"
    case .bottomSpace: "bottom-space"
    case .loadMore: "load-more"
    }
  }
}

private struct ChatMessageSearchKey: Hashable {
  let threadID: String?
  let query: String
  let filterMask: Int
  let fileByteCount: Int64
}

private struct ChatPresentationKey: Hashable {
  let threadID: String?
  let fileByteCount: Int64
  let messageIDs: [String]
}

private enum ChatFilterChoice: String, CaseIterable, Identifiable {
  case prompts = "Prompts"
  case responses = "Responses"
  case tools = "Tools"
  case other = "Other"

  var id: String { rawValue }

  var filter: ChatMessageFilter {
    switch self {
    case .prompts: .prompts
    case .responses: .responses
    case .tools: .tools
    case .other: .other
    }
  }
}

private struct ChatFilterButton: View {
  let choice: ChatFilterChoice
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: selected ? "checkmark" : "circle")
          .font(.system(size: 8.5, weight: .semibold))
        Text(choice.rawValue).font(AIMTheme.sans(9.5, weight: .medium))
      }
      .foregroundStyle(selected ? AIMTheme.activeInk : AIMTheme.ink)
      .padding(.horizontal, 8)
      .frame(height: 24)
      .background(selected ? AIMTheme.active : AIMTheme.control)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
      .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
    .accessibilityLabel("Show \(choice.rawValue.lowercased())")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct ChatFilteredCopyButton: View {
  let messages: [ChatMessage]
  @State private var copied = false

  var body: some View {
    Button {
      let text = ChatTranscriptExport.text(for: messages)
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
      HStack(spacing: 6) {
        AIMIcon(name: copied ? .check : .copy, size: 10)
        Text(copied ? "Copied" : "Copy shown")
          .font(AIMTheme.sans(9.5, weight: .medium))
      }
      .foregroundStyle(copied ? AIMTheme.green : AIMTheme.ink)
      .padding(.horizontal, 9)
      .frame(height: 28)
      .background(AIMTheme.control)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
      .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
    .disabled(messages.isEmpty)
    .opacity(messages.isEmpty ? 0.45 : 1)
    .help("Copy the messages currently shown")
    .accessibilityLabel(copied ? "Copied" : "Copy shown messages")
  }
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
        Text(message.role.displayName)
          .font(AIMTheme.sans(9.5, weight: .semibold))
        if let timestamp = message.timestamp {
          Text("·")
          Text(timestamp, style: .time)
        }
        ChatCopyButton(text: message.text, label: "Copy message", emphasized: hovered)
      }
      .font(AIMTheme.sans(9.5))
      .foregroundStyle(AIMTheme.muted)

      switch message.role {
      case .user:
        ChatMessageBlocks(presentation: presentation, fallbackText: fallbackText)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .frame(maxWidth: 460, alignment: .leading)
          .background(AIMTheme.chatUserSurface)
          .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
      case .assistant:
        HStack(alignment: .top, spacing: 12) {
          Rectangle().fill(AIMTheme.titleArt).frame(width: 2)
          ChatMessageBlocks(presentation: presentation, fallbackText: fallbackText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: 620, alignment: .leading)
      case .tool:
        HStack(alignment: .top, spacing: 10) {
          Rectangle().fill(AIMTheme.amber).frame(width: 2)
          ChatMessageBlocks(presentation: presentation, fallbackText: fallbackText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: 620, alignment: .leading)
        .background(AIMTheme.chatCodeSurface)
        .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
      case .other:
        HStack(alignment: .top, spacing: 10) {
          Rectangle().fill(AIMTheme.muted).frame(width: 2)
          ChatMessageBlocks(presentation: presentation, fallbackText: fallbackText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: 620, alignment: .leading)
      }
    }
    .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
    .padding(.horizontal, 12)
    .padding(.top, separated ? 10 : 4)
    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
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
                      AIMCopyablePath(path: item.destination.path).font(AIMTheme.mono(9)).foregroundStyle(
                        AIMTheme.muted
                      )
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
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
      .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
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

  private var selectedIsDefault: Bool {
    model.selectedAccountID.map { $0 == model.status?.defaultAccountID } ?? false
  }

  var body: some View {
    VStack(spacing: 0) {
      ImportHeader(
        title: step == 1 ? "Add Account" : (step == 2 ? "Sign In" : "Account Ready"),
        closeDisabled: model.isBusy
      ) {
        model.closeAccountModal()
      }
      Group {
        switch step {
        case 1: providerPage
        case 2: signInPage
        default: completedPage
        }
      }
      .disabled(model.isBusy)
    }
    .font(AIMTheme.sans(13))
    .foregroundStyle(AIMTheme.ink)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AIMTheme.panel)
    .overlay(alignment: .bottom) {
      if let error = model.errorMessage {
        ErrorBar(message: error, copy: { model.copyWarnings([error]) }) {
          model.errorMessage = nil
        }
        .padding(.horizontal, AIMTheme.modalOuterInset)
        .padding(.bottom, 52)
      } else if model.isBusy {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Checking account…")
            .font(AIMTheme.sans(11))
            .foregroundStyle(AIMTheme.muted)
        }
        .padding(.bottom, 58)
      }
    }
  }

  private var providerPage: some View {
    VStack(spacing: 0) {
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
                Badge(text: "WIP", color: AIMTheme.disabledControl, ink: AIMTheme.disabledInk)
              }
            }
            .padding(.horizontal, AIMTheme.panelContentInset)
            .frame(height: 62)
            .foregroundStyle(selected ? AIMTheme.activeInk : AIMTheme.ink)
            .background {
              AIMHoverBackground(base: selected ? AIMTheme.active
                  : index.isMultiple(of: 2) ? AIMTheme.panel : AIMTheme.listStripe,
                highlight: AIMTheme.listHover, hovered: hoveredProviderID == provider.id && !selected)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(AIMPressButtonStyle())
          .disabled(!available)
          .opacity(available ? 1 : 0.64)
          .onHover { hoveredProviderID = $0 && available ? provider.id : nil }
          .accessibilityLabel(provider.displayName)
          .accessibilityHint(available ? "Available" : unavailableCopy(provider))
        }
      }
      .background(AIMTheme.panel2)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))

      Spacer(minLength: AIMTheme.modalSectionSpacing)

      ImportFooter(step: step, labels: ["Provider", "Sign in", "Done"]) {
        AIMButton(title: "Advanced Import…", icon: .folder, disabled: model.isBusy) {
          Task { await model.beginAdvancedImport() }
        }
      } trailing: {
        AIMButton(
          title: "Continue", tone: .primary,
          disabled: selectedProvider?.availability != .enabled || model.isBusy
        ) {
          Task { await model.startAccountLogin() }
        }
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.vertical, 16)
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
                "Sign in through a private temporary home. The saved account becomes available for new Codex sessions after you finish."
              )
              .font(AIMTheme.sans(12))
              .foregroundStyle(AIMTheme.muted)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          Notice(
            text: model.accountLoginMessage
              ?? "Finish signing in to Codex, then return here and choose Check Now.",
            tone: model.accountLoginState == .needsAttention ? AIMTheme.amber : AIMTheme.blue
          )
          Group {
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
              Text("When the browser reports success, return to Switch and check the account.")
                .font(AIMTheme.sans(11))
                .foregroundStyle(AIMTheme.muted)
            }
          }
          .frame(minHeight: 52, alignment: .topLeading)
        }
        .padding(20)
      }

      Spacer(minLength: AIMTheme.modalSectionSpacing)

      ImportFooter(step: step, labels: ["Provider", "Sign in", "Done"]) {
        AIMButton(title: "Cancel sign-in") {
          Task { await model.cancelAccountLogin() }
        }
      } trailing: {
        if model.accountLoginState != .credentialChoiceRequired {
          AIMButton(title: "Check Now", icon: .refresh, tone: .primary) {
            Task { await model.checkAccountLogin() }
          }
        }
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.vertical, 16)
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
          Text("The account is ready for new Codex sessions. Shared settings and chats stay in place.")
            .font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
          HStack(spacing: 6) {
            AIMButton(
              title: selectedIsDefault ? AccountActionCopy.usingDefault : AccountActionCopy.use,
              icon: selectedIsDefault ? .doubleCheck : .check,
              tone: .primary, disabled: model.isBusy
            ) {
              Task { await model.switchDefault() }
            }
            AIMButton(title: "Open Codex", icon: .play, disabled: model.isBusy) {
              Task { await model.openAccount() }
            }
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      ImportFooter(step: step, labels: ["Provider", "Sign in", "Done"]) {
        if let accountID = model.selectedAccountID {
          AIMButton(title: "Refresh usage", icon: .refresh, disabled: model.isBusy) {
            Task { await model.refreshUsage(accountID: accountID) }
          }
        }
      } trailing: {
        AIMButton(title: "Done") { model.closeAccountModal() }
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.vertical, 16)
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private func unavailableCopy(_ provider: ProviderDescriptor) -> String {
    provider.unavailableReason ?? "Account setup is not available in this version."
  }
}

private struct ImportFlow: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    VStack(spacing: 0) {
      ImportHeader(
        title: title,
        closeDisabled: model.isBusy
      ) {
        model.closeAccountModal()
      }
      Group {
        if let result = model.importResult {
          ImportResultPage(result: result, model: model)
        } else if let plan = model.importPlan {
          ImportReviewPage(plan: plan, model: model)
        } else {
          SourcePage(model: model)
        }
      }
      .disabled(model.isBusy)
    }.font(AIMTheme.sans(13)).foregroundStyle(AIMTheme.ink).frame(
      maxWidth: .infinity, maxHeight: .infinity
    )
    .background(AIMTheme.panel)
    .overlay(alignment: .bottom) {
      if let error = model.errorMessage {
        ErrorBar(message: error, copy: { model.copyWarnings([error]) }) {
          model.errorMessage = nil
        }
        .padding(.horizontal, AIMTheme.modalOuterInset)
        .padding(.bottom, 52)
      } else if model.isBusy {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Working…").font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
        }
        .padding(.bottom, 58)
      }
    }
  }
  private var step: Int { model.importResult != nil ? 3 : model.importPlan != nil ? 2 : 1 }
  private var title: String {
    step == 1 ? "Import Account" : step == 2 ? "Review Import" : "Import Result"
  }
}

private struct ImportHeader: View {
  let title: String
  let closeDisabled: Bool
  let close: () -> Void
  @State private var closeHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      Text(title)
        .font(AIMTheme.sans(22, weight: .semibold))
        .tracking(-0.35)
        .lineLimit(1)
        .padding(.leading, AIMTheme.modalOuterInset)
      Spacer(minLength: AIMTheme.modalOuterInset)
      Button(action: close) {
        AIMIcon(name: .close, size: 15)
          .foregroundStyle(closeHovered && !closeDisabled ? Color.white : AIMTheme.ink)
          .frame(
            width: AIMTheme.windowControlSize,
            height: AIMTheme.modalTitlebarHeight
          )
          .background {
            AIMHoverBackground(base: AIMTheme.modalCloseSurface, highlight: AIMTheme.closeHover,
              hovered: closeHovered && !closeDisabled)
          }
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
        reduceMotion ? nil : .easeOut(duration: AIMMotion.state),
        value: closeDisabled
      )
    }
    .frame(height: AIMTheme.modalTitlebarHeight)
    .background(AIMTheme.panel2)
    .accessibilityIdentifier("import-modal-titlebar")
  }
}

private struct ImportFooter<Leading: View, Trailing: View>: View {
  let step: Int
  var labels = ["Source", "Review", "Done"]
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing

  var body: some View {
    ZStack {
      HStack(spacing: 6) {
        leading
        Spacer(minLength: 16)
        trailing
      }
      ImportSteps(step: step, labels: labels)
        .fixedSize(horizontal: true, vertical: true)
        .allowsHitTesting(false)
    }
    .frame(height: 30)
    .accessibilityIdentifier("import-modal-footer")
  }
}

private struct ImportSteps: View {
  let step: Int
  let labels: [String]
  var body: some View {
    HStack(spacing: 1) {
      ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
        HStack(spacing: 5) {
          Text("\(index + 1)").font(AIMTheme.mono(9, weight: .semibold))
          Text(label).font(AIMTheme.sans(10, weight: .medium))
        }
        .foregroundStyle(index < step ? AIMTheme.activeInk : AIMTheme.muted)
        .padding(.horizontal, 10)
        .frame(height: AIMTheme.modalStepHeight)
        .background(index < step ? AIMTheme.active : AIMTheme.control)
      }
    }.accessibilityElement(children: .ignore)
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
        }.padding(.horizontal, 6).padding(.vertical, 8)
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
                    AIMCopyablePath(path: source.path.path).font(AIMTheme.mono(11)).foregroundStyle(
                      selected ? AIMTheme.activeInk : AIMTheme.muted)
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
                  .frame(minHeight: 64).background {
                    AIMHoverBackground(base: selected ? AIMTheme.active.opacity(0.70)
                        : index.isMultiple(of: 2) ? .clear : AIMTheme.panel2.opacity(0.55),
                      highlight: AIMTheme.panel2, hovered: hoveredSourceID == source.id && !selected)
                  }.contentShape(Rectangle())
                  .foregroundStyle(
                    selected ? AIMTheme.activeInk : AIMTheme.ink)
                  .opacity(isEnabled && supported ? 1 : 0.58)
              }.buttonStyle(AIMPressButtonStyle())
                .disabled(!supported)
                .help(source.inspectionError ?? source.path.path)
                .onHover { hoveredSourceID = $0 && isEnabled && supported ? source.id : nil }
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
        }.padding(.horizontal, 6).padding(.vertical, 8)
      }
      Text(
        model.importMode == .authOnly
          ? "Saves account access. Settings and chats stay in the current Codex home. The source stays unchanged."
          : "Reviews Codex-home conflicts and adds source chats to the merged library. Everything affected is backed up first."
      ).font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted).frame(
        maxWidth: .infinity, alignment: .leading)
      ImportFooter(step: 1) {
        HStack(spacing: 4) {
          AIMButton(title: "Choose Codex folder…", icon: .folder) {
            Task { await model.chooseSource() }
          }
          AIMIconButton(icon: .refresh, label: "Refresh sources") { Task { await model.discover() } }
        }
      } trailing: {
        AIMButton(
          title: "Review import", tone: .primary,
          disabled: model.selectedSourceID == nil
            || model.discoveries.first(where: { $0.id == model.selectedSourceID })?.support
              != .supportedChatGPT
        ) { Task { await model.reviewImport() } }
      }
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.vertical, 16).frame(
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
        ).background {
          AIMHoverBackground(base: !isEnabled ? AIMTheme.disabledControl
              : selected ? AIMTheme.active : AIMTheme.control,
            highlight: AIMTheme.controlHover, hovered: hover && !selected && isEnabled)
        }
        .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
    }.buttonStyle(AIMPressButtonStyle()).accessibilityAddTraits(selected ? .isSelected : [])
      .onHover { hover = $0 && isEnabled }
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
                    AIMCopyablePath(path: conflict.relativePath).font(AIMTheme.mono(11, weight: .semibold))
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
                  AIMCopyablePath(path: entry.relativePath).font(AIMTheme.mono(10))
                  Spacer()
                  Text(entry.disposition).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
                }.padding(.horizontal, 16).frame(height: 36)
              }
            }
          }
        }
      }
      ImportFooter(step: 2) {
        AIMButton(title: "Back") { model.resetImport() }
      } trailing: {
        AIMButton(title: "Import account", tone: .primary, disabled: !complete || model.isBusy) {
          Task { await model.commitImport() }
        }
      }
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.vertical, 16)
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
      ImportFooter(step: 3) {
        AIMButton(title: "Refresh usage", icon: .refresh, disabled: model.isBusy) {
          Task { await model.refreshUsage(accountID: result.account.id) }
        }
      } trailing: {
        AIMButton(title: "Done", tone: .primary) {
          model.closeAccountModal()
        }
      }
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.vertical, 16)
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
  fileprivate var attentionLabel: String? {
    switch self {
    case .imported: "Check required"
    case .needsSignIn: "Needs sign-in"
    case .verifiedLocally, .verifiedWithCodex: nil
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
