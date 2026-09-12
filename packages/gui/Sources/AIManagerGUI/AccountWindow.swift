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
  init(title: String, rootView: Content) {
    let fixedSize = AIManagerWindow.fixedSize
    let window = AIManagerWindow(
      contentRect: NSRect(origin: .zero, size: fixedSize),
      styleMask: [.closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = title
    window.isOpaque = true
    window.backgroundColor = NSColor(AIMTheme.canvas)
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
    let restoredFrame = window.setFrameUsingName(AIManagerWindow.frameAutosaveName, force: true)
    window.setContentSize(fixedSize)
    if !restoredFrame { window.center() }
    window.setFrameAutosaveName(AIManagerWindow.frameAutosaveName)
    super.init(window: window)
    window.delegate = self
  }
  @available(*, unavailable) required init?(coder: NSCoder) { nil }
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

private enum Page: String, CaseIterable {
  case accounts = "Accounts"
  case settings = "Shared Settings"
  case history = "Chat History"
  case recovery = "Recovery"
  var icon: AIMIcon.Name {
    switch self {
    case .accounts: .account
    case .settings: .settings
    case .history: .history
    case .recovery: .recovery
    }
  }
  var subtitle: String {
    switch self {
    case .accounts: "Import, verify, and switch accounts"
    case .settings: "One configuration across every account"
    case .history: "The merged resume library"
    case .recovery: "Backups and interrupted operations"
    }
  }
}

struct AccountWindow: View {
  @ObservedObject var model: AccountViewModel
  @StateObject private var target = WindowTarget()
  @State private var page: Page = .accounts
  @State private var themeOverride: ColorScheme?
  @State private var showFocusIndicators = false
  @State private var refreshHovered = false
  @Environment(\.colorScheme) private var systemScheme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var dark: Bool { (themeOverride ?? systemScheme) == .dark }

  init(model: AccountViewModel, initialPageIndex: Int = 0) {
    self.model = model
    let pages = Page.allCases
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
              switch page {
              case .accounts: AccountsPage(model: model)
              case .settings:
                SharedSettingsPage(model: model, showFocusIndicators: $showFocusIndicators)
              case .history: HistoryPage(model: model)
              case .recovery: RecoveryPage(model: model)
              }
            }
            .id(page)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 3)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
              if let error = model.errorMessage, !model.showImport {
                ErrorBar(message: error) { model.errorMessage = nil }.padding(12)
              }
            }
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
          Color.black.opacity(0.34).ignoresSafeArea()
          ImportFlow(model: model)
            .frame(
              width: min(780, geometry.size.width - 48),
              height: min(600, geometry.size.height - 48)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(dark ? 0.22 : 0.1), radius: 34, y: 14)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4)))
            .accessibilityElement(children: .contain)
        }
      }
    }
    .font(AIMTheme.sans(13)).foregroundStyle(AIMTheme.ink).background(AIMTheme.canvas)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: page)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.showImport)
    .environment(\.aimDarkMode, dark)
    .environment(\.aimFocusIndicatorsEnabled, showFocusIndicators)
    .focusEffectDisabled(!showFocusIndicators)
    .preferredColorScheme(themeOverride)
    .background(
      WindowReader { window in
        target.window = window
        applyAppearance(to: window)
        applyFocusPolicy(to: window)
      }
    ).ignoresSafeArea(.container, edges: .top)
    .onChange(of: dark) { _, _ in
      if let window = target.window { applyAppearance(to: window) }
    }
    .onChange(of: showFocusIndicators) { _, _ in
      if let window = target.window { applyFocusPolicy(to: window) }
    }
    .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.load() } } }
  }

  private func applyAppearance(to window: NSWindow) {
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
      ForEach(Page.allCases, id: \.self) { item in
        RailButton(icon: item.icon, label: item.rawValue, active: page == item) { page = item }
      }
      Spacer()
      RailButton(icon: dark ? .sun : .moon, label: dark ? "Light mode" : "Dark mode", active: false)
      {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20)) {
          themeOverride = dark ? .light : .dark
        }
      }
      RailButton(icon: .plus, label: "Import account", active: false) {
        Task { await model.beginImport() }
      }
    }.frame(width: AIMTheme.railWidth).background(AIMTheme.rail).overlay(alignment: .trailing) {
      Rectangle().fill(AIMTheme.lineSoft.opacity(0.7)).frame(width: 1)
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
          .foregroundStyle(refreshHovered ? AIMTheme.ink : AIMTheme.muted)
          .frame(width: 32, height: 32).contentShape(Rectangle())
      }
      .buttonStyle(AIMPressButtonStyle())
      .disabled(model.isBusy)
      .opacity(model.isBusy ? 0.42 : 1)
      .onHover { refreshHovered = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: refreshHovered)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: model.isBusy)
      .help(refreshHelp)
      .accessibilityLabel(model.isDemo ? "Refresh demo data" : "Refresh accounts")
      .accessibilityHint(refreshHelp)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }.padding(.leading, 24).padding(.trailing, 24)
      .frame(height: AIMTheme.topbarHeight).background(AIMTheme.canvas)
  }

  private var refreshHelp: String {
    guard let refreshedAt = model.refreshedAt else {
      return model.isDemo ? "Refresh demo data" : "Refresh accounts"
    }
    return "Last refreshed \(refreshedAt.formatted(date: .omitted, time: .shortened))"
  }
}

private struct RailTop: View {
  let close: () -> Void, minimize: () -> Void
  @State private var hover = false
  @State private var closeHover = false
  @State private var minimizeHover = false
  @State private var pendingHide: Task<Void, Never>?
  @FocusState private var closeFocused: Bool
  @FocusState private var minimizeFocused: Bool
  @Environment(\.aimFocusIndicatorsEnabled) private var focusIndicatorsEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var showMinimize: Bool {
    hover || (focusIndicatorsEnabled && (closeFocused || minimizeFocused))
  }
  var body: some View {
    ZStack(alignment: .topLeading) {
      if showMinimize {
        Button(action: minimize) {
          AIMIcon(name: .minimize, size: 15).foregroundStyle(
            minimizeHover ? AIMTheme.ink : AIMTheme.muted
          )
          .frame(width: AIMTheme.windowControlSize, height: AIMTheme.windowControlSize)
          .background(minimizeHover ? AIMTheme.minimizeHover : AIMTheme.minimizeControl)
          .contentShape(Rectangle())
        }.buttonStyle(AIMPressButtonStyle()).focusable(focusIndicatorsEnabled).focused($minimizeFocused)
          .accessibilityLabel("Minimize window")
          .offset(x: AIMTheme.windowControlSize)
          .transition(reduceMotion ? .identity : .offset(x: -AIMTheme.windowControlSize))
          .onHover { value in
            minimizeHover = value
            updateHover(value)
          }
      }
      Button(action: close) {
        AIMIcon(name: .close, size: 15).foregroundStyle(Color(nsColor: .systemRed))
          .frame(width: AIMTheme.windowControlSize, height: AIMTheme.windowControlSize)
          .background(closeHover ? Color(nsColor: .systemRed).opacity(0.12) : AIMTheme.rail)
          .contentShape(Rectangle())
      }.buttonStyle(AIMPressButtonStyle()).focusable(focusIndicatorsEnabled).focused($closeFocused)
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
    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: showMinimize)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: minimizeHover)
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
  let icon: AIMIcon.Name, label: String, active: Bool, action: () -> Void
  @State private var hover = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Button(action: action) {
      AIMIcon(name: icon).frame(width: 48, height: 48).foregroundStyle(
        active ? AIMTheme.activeInk : (hover ? AIMTheme.ink : AIMTheme.railIdle)
      ).background(active ? AIMTheme.active : (hover ? AIMTheme.panel2 : .clear))
        .contentShape(Rectangle())
    }.buttonStyle(AIMPressButtonStyle()).help(label).accessibilityLabel(label).accessibilityAddTraits(
      active ? .isSelected : []
    ).onHover { hover = $0 }.animation(
      reduceMotion ? nil : .easeOut(duration: 0.10), value: hover)
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
              ? AIMTheme.canvas : (tone == .danger && hover ? AIMTheme.statusInk : AIMTheme.ink))
        ).background(
          unavailable
            ? AIMTheme.disabledControl
            : (tone == .primary
              ? (hover ? AIMTheme.primaryHover : AIMTheme.ink)
              : (tone == .danger && hover ? AIMTheme.red : (hover ? AIMTheme.controlHover : AIMTheme.control)))
        ).overlay {
          if focused, focusIndicatorsEnabled {
            RoundedRectangle(cornerRadius: 3).stroke(AIMTheme.blue, lineWidth: 2)
          }
        }.clipShape(RoundedRectangle(cornerRadius: 3))
    }
    .buttonStyle(AIMPressButtonStyle()).focused($focused).disabled(disabled).onHover {
      hover = $0 && !unavailable
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: hover)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: unavailable)
  }
}
private struct Badge: View {
  let text: String, color: Color
  var body: some View {
    Text(text.uppercased()).font(AIMTheme.sans(10, weight: .semibold)).padding(.horizontal, 6)
      .frame(height: 18).foregroundStyle(AIMTheme.statusInk).background(color).clipShape(
        RoundedRectangle(cornerRadius: 3))
  }
}

private struct AccountsPage: View {
  @ObservedObject var model: AccountViewModel
  @State private var importHovered = false
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
                }.buttonStyle(AIMPressButtonStyle())
              }
              if model.status?.accounts.isEmpty != false {
                Text("No accounts yet.").font(AIMTheme.sans(12)).foregroundStyle(AIMTheme.muted)
                  .padding(16).frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          Button {
            Task { await model.beginImport() }
          } label: {
            HStack {
              AIMIcon(name: .plus, size: 13)
              Text("Import account")
              Spacer()
            }.font(AIMTheme.sans(12, weight: .medium)).padding(.horizontal, 12).frame(height: 40)
              .background(importHovered ? AIMTheme.controlHover : AIMTheme.panel2)
          }.buttonStyle(AIMPressButtonStyle()).keyboardShortcut("i", modifiers: [.command])
            .onHover { importHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: importHovered)
        }
      }.frame(width: AIMTheme.listWidth)
      if let account = model.selectedAccount {
        AccountDetail(account: account, model: model)
      } else {
        EmptyAccountView(model: model)
      }
    }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
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
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: selected)
  }
}
private struct EmptyAccountView: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    AIMPanel(title: "Account") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Import your first Codex account").font(AIMTheme.sans(18, weight: .semibold))
        Text(
          "Choose a Codex home to review credentials, shared settings, chat history, and its backup plan."
        ).foregroundStyle(AIMTheme.muted).frame(maxWidth: 520, alignment: .leading)
        AIMButton(title: "Import account", icon: .plus, tone: .primary) {
          Task { await model.beginImport() }
        }
      }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }.frame(maxWidth: .infinity)
  }
}

private struct AccountDetail: View {
  let account: AccountRecord
  @ObservedObject var model: AccountViewModel
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
        AIMPanel(title: "Account details") {
          VStack(spacing: 0) {
            DetailRow(label: "Profile", value: account.home.path)
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
                    ).lineLimit(1)
                  }
                  Spacer()
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
        if let notice = model.notice { Notice(text: notice, tone: AIMTheme.blue) }
      }.frame(maxWidth: .infinity)
    }.frame(maxWidth: .infinity)
  }
  @ViewBuilder private var actions: some View {
    AIMButton(
      title: "Use for new Codex sessions", tone: .primary,
      disabled: account.id == model.status?.defaultAccountID || model.isBusy
    ) { Task { await model.switchDefault() } }
    AIMButton(title: "Open Codex", icon: .play, disabled: model.isBusy || !issues.isEmpty) {
      Task { await model.openAccount() }
    }
    AIMButton(title: "Check account files", icon: .check, disabled: model.isBusy) {
      Task { await model.verify() }
    }
    AIMButton(title: "Copy path", icon: .copy) { model.copyProfilePath() }
  }
}
private struct DetailRow: View {
  let label: String, value: String
  var zebra = false
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(label).font(AIMTheme.sans(11, weight: .medium)).frame(width: 118, alignment: .leading)
      Text(value).font(AIMTheme.mono(10)).foregroundStyle(AIMTheme.muted).lineLimit(1)
        .truncationMode(.middle).textSelection(.enabled)
      Spacer()
    }.padding(.horizontal, 16).frame(minHeight: 40).background(
      zebra ? AIMTheme.panel2.opacity(0.55) : .clear)
  }
}

private struct SharedSettingsPage: View {
  @ObservedObject var model: AccountViewModel
  @Binding var showFocusIndicators: Bool
  @AppStorage(AIManagerWindowBehavior.minimizeToTrayKey) private var minimizeToTray = false
  private let shared = [
    "config.toml", "AGENTS.md", "agents", "rules", "context", "skills", "plugins", "hooks.json",
    "sessions", "archived_sessions",
  ]
  private var visibleShared: [String] {
    model.isDemo
      ? shared
      : shared.filter {
        FileManager.default.fileExists(atPath: model.paths.sharedRoot.appending(path: $0).path)
      }
  }
  var body: some View {
    AIMScrollView {
      VStack(spacing: 8) {
        AIMPanel(title: "App behavior") {
          VStack(spacing: 0) {
            settingRow(isOn: $minimizeToTray, title: "Minimize to tray") {
              Text("Hide the window and keep IIA Directeur available from its menu-bar icon.")
            }
            settingRow(isOn: $showFocusIndicators, title: "Keyboard focus indicators", zebra: true) {
              Text("Show outlines only while keyboard controls have focus.")
            }
          }
        }
        if model.isDemo {
          AIMPanel(title: "Demo states") {
            HStack(spacing: 4) {
              AIMButton(title: "Sample accounts") { model.reset(to: .demo) }
              AIMButton(title: "Empty state") { model.reset(to: .empty) }
              AIMButton(title: "Issues and recovery") { model.reset(to: .allStates) }
              AIMButton(title: "Refresh demo data", icon: .refresh, disabled: model.isBusy) {
                Task { await model.refresh() }
              }
              Spacer()
              AIMButton(title: "Show demo error", tone: .danger) { model.showDemoError() }
            }.padding(12)
          }
        }
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
            tone: AIMTheme.amber)
        }
        if let notice = model.notice { Notice(text: notice, tone: AIMTheme.blue) }
      }
    }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
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
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    .background(zebra ? AIMTheme.panel2.opacity(0.55) : .clear)
  }
}

private struct HistoryPage: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    AIMScrollView {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          Metric(
            label: "Accounts", value: "\(model.status?.accounts.count ?? 0)",
            detail: "share one library")
          Metric(label: "Library", value: "Merged", detail: "active + archived")
          Metric(label: "Indexes", value: "Per profile", detail: "kept independent")
        }
        AIMPanel(title: "Resume availability") {
          VStack(spacing: 0) {
            HStack {
              Header("Account")
              Spacer()
              Header("Active")
              Header("Archived")
              Header("Index")
            }.padding(.horizontal, 16).frame(height: 30).background(AIMTheme.panel2)
            ForEach(Array((model.status?.accounts ?? []).enumerated()), id: \.element.id) {
              index, account in
              let history = model.history(for: account)
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(account.identity.heroName).font(AIMTheme.sans(12, weight: .medium))
                  Text(account.home.lastPathComponent).font(AIMTheme.mono(9)).foregroundStyle(
                    AIMTheme.muted)
                }
                Spacer()
                Text("\(history.activeTranscripts)").font(AIMTheme.mono(11)).frame(
                  width: 70, alignment: .trailing)
                Text("\(history.archivedTranscripts)").font(AIMTheme.mono(11)).frame(
                  width: 70, alignment: .trailing)
                AIMIcon(name: history.hasIndexes ? .check : .warning, size: 12)
                  .foregroundStyle(history.hasIndexes ? AIMTheme.green : AIMTheme.amber)
                  .frame(width: 70, alignment: .trailing)
              }.padding(.horizontal, 16).frame(minHeight: 44).background(
                index.isMultiple(of: 2) ? .clear : AIMTheme.panel2.opacity(0.55))
            }
          }
        }
        Notice(
          text:
            "New Codex sessions opened from either account can resume the same merged history. Existing processes keep the account they started with.",
          tone: AIMTheme.blue)
      }
    }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
  }
}
private struct Metric: View {
  let label: String, value: String, detail: String
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label.uppercased()).font(AIMTheme.sans(9, weight: .semibold)).tracking(0.7)
        .foregroundStyle(AIMTheme.muted)
      Text(value).font(AIMTheme.mono(20, weight: .medium))
      Text(detail).font(AIMTheme.sans(9)).foregroundStyle(AIMTheme.muted)
    }.padding(12).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).background(
      AIMTheme.panel
    ).clipShape(RoundedRectangle(cornerRadius: 3))
  }
}
private struct Header: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text.uppercased()).font(AIMTheme.sans(10, weight: .semibold)).foregroundStyle(
      AIMTheme.muted
    ).frame(width: text == "Account" ? nil : 70, alignment: .trailing)
  }
}

private struct RecoveryPage: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    AIMScrollView {
      VStack(spacing: 8) {
        AIMPanel(title: "Pending operations") {
          VStack(spacing: 0) {
            if let operations = model.status?.pendingRecovery, !operations.isEmpty {
              ForEach(Array(operations.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 12) {
                  AIMIcon(name: .warning, size: 15).foregroundStyle(AIMTheme.amber)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(item.kind.capitalized).font(AIMTheme.sans(12, weight: .semibold))
                    Text(item.destination.path).font(AIMTheme.mono(9)).foregroundStyle(
                      AIMTheme.muted
                    ).lineLimit(1)
                  }
                  Spacer()
                  Badge(text: item.phase.rawValue, color: AIMTheme.amber)
                }.padding(.horizontal, 16).frame(minHeight: 48).background(
                  index.isMultiple(of: 2) ? .clear : AIMTheme.panel2.opacity(0.55))
              }
            } else {
              Text("No interrupted operations need recovery.").font(AIMTheme.sans(12))
                .foregroundStyle(AIMTheme.muted).padding(16).frame(
                  maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        AIMPanel(title: "Recovery policy") {
          VStack(spacing: 0) {
            DetailRow(
              label: "Before import", value: "Review destination, conflicts, and required space")
            DetailRow(
              label: "During import", value: "Back up, stage, verify, then publish", zebra: true)
            DetailRow(
              label: "On failure", value: "Keep prior credentials and preserve a recovery journal")
          }
        }
        if model.isDemo { RecoveryExamples(model: model) }
        HStack {
          Text("Recovery never deletes source data.").font(AIMTheme.sans(11)).foregroundStyle(
            AIMTheme.muted)
          Spacer()
          AIMButton(
            title: "Recover operations", icon: .recovery, tone: .primary,
            disabled: model.status?.pendingRecovery.isEmpty != false || model.isBusy
          ) { Task { await model.recover() } }
        }.padding(12).background(AIMTheme.panel)
        if let notice = model.notice { Notice(text: notice, tone: AIMTheme.blue) }
      }
    }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
  }
}

private struct RecoveryExamples: View {
  @ObservedObject var model: AccountViewModel
  var body: some View {
    AIMPanel(title: "Recovery examples") {
      VStack(spacing: 0) {
        RecoveryExampleRow(
          title: "Regular conversation", detail: "Complete snapshot before replacement",
          location: "~/Documents/IIA Directeur Backups", state: "Ready", color: AIMTheme.green)
        RecoveryExampleRow(
          title: "Incremental", detail: "Only changes since the last snapshot",
          location: "Local backup set · 18 MB", state: "Current", color: AIMTheme.blue, zebra: true)
        RecoveryExampleRow(
          title: "Custom location", detail: "A selected folder outside the managed profile",
          location: "/Volumes/Studio Archive/Codex", state: "Available", color: AIMTheme.green)
        VStack(spacing: 0) {
          RecoveryExampleRow(
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
          }.padding(.horizontal, 16).padding(.bottom, 10).background(AIMTheme.panel2.opacity(0.55))
        }
      }
    }
  }
}

private struct RecoveryExampleRow: View {
  let title: String, detail: String, location: String, state: String, color: Color
  var zebra = false
  var body: some View {
    HStack(spacing: 12) {
      AIMIcon(name: .recovery, size: 14).foregroundStyle(color)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(AIMTheme.sans(11, weight: .semibold))
        Text(detail).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
      }
      Spacer(minLength: 16)
      Text(location).font(AIMTheme.mono(9)).foregroundStyle(AIMTheme.muted).lineLimit(1)
      Badge(text: state, color: color)
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    .background(zebra ? AIMTheme.panel2.opacity(0.55) : .clear)
  }
}
private struct Notice: View {
  let text: String, tone: Color
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      AIMIcon(name: .warning, size: 14).foregroundStyle(tone)
      Text(text).font(AIMTheme.sans(11)).textSelection(.enabled)
      Spacer()
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AIMTheme.panel)
  }
}
private struct ErrorBar: View {
  let message: String, dismiss: () -> Void
  var body: some View {
    HStack(spacing: 10) {
      AIMIcon(name: .warning, size: 14).foregroundStyle(AIMTheme.red)
      Text(message).font(AIMTheme.sans(11)).lineLimit(2).textSelection(.enabled)
      Spacer()
      AIMButton(title: "Dismiss", action: dismiss)
    }.padding(12).background(AIMTheme.panel)
  }
}

private struct ImportFlow: View {
  @ObservedObject var model: AccountViewModel
  @State private var closeHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Text(title).font(AIMTheme.sans(22, weight: .semibold)).tracking(-0.55)
        Spacer()
        ImportSteps(step: step)
        Button {
          model.resetImport()
          model.showImport = false
        } label: {
          AIMIcon(name: .close, size: 15)
            .frame(width: AIMTheme.windowControlSize, height: AIMTheme.windowControlSize)
            .background(closeHovered ? AIMTheme.controlHover : AIMTheme.control)
            .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
        }.buttonStyle(AIMPressButtonStyle()).keyboardShortcut(.cancelAction)
          .accessibilityLabel("Close import")
          .onHover { closeHovered = $0 }
          .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: closeHovered)
      }.padding(.leading, AIMTheme.modalOuterInset).frame(height: 56).background(AIMTheme.panel2)
      if let error = model.errorMessage {
        ErrorBar(message: error) { model.errorMessage = nil }.padding(.horizontal, 24).padding(
          .top, 12)
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
      .id(step)
      .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 3)))
      .disabled(model.isBusy)
      if model.isBusy {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Working…").font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted)
        }.padding(10).transition(reduceMotion ? .identity : .opacity)
      }
    }.font(AIMTheme.sans(13)).foregroundStyle(AIMTheme.ink).background(AIMTheme.panel).frame(
      maxWidth: .infinity, maxHeight: .infinity
    )
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: step)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: model.isBusy)
  }
  private var step: Int { model.importResult != nil ? 3 : model.importPlan != nil ? 2 : 1 }
  private var title: String {
    step == 1 ? "Import Codex Account" : step == 2 ? "Review Codex Import" : "Codex Import Result"
  }
}
private struct ImportSteps: View {
  let step: Int
  private let labels = ["Source", "Review", "Done"]
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
  }
}

private struct SourcePage: View {
  @ObservedObject var model: AccountViewModel
  @State private var hoveredSourceID: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  var body: some View {
    VStack(spacing: 8) {
      Text("Choose a Codex profile to import.")
        .font(AIMTheme.sans(12))
        .foregroundStyle(AIMTheme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
      AIMPanel(title: "Source") {
        AIMScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(model.discoveries.enumerated()), id: \.element.id) { index, source in
              Button {
                model.selectedSourceID = source.id
              } label: {
                HStack(spacing: 12) {
                  ZStack {
                    Rectangle().stroke(AIMTheme.ink.opacity(0.35), lineWidth: 1)
                    if source.id == model.selectedSourceID { AIMIcon(name: .check, size: 11) }
                  }.frame(width: 14, height: 14)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(source.identity?.displayName ?? source.support.label).font(
                      AIMTheme.sans(12, weight: .medium))
                    Text(source.path.path).font(AIMTheme.mono(11)).foregroundStyle(AIMTheme.muted)
                      .lineLimit(1)
                    Text(
                      "\(source.settings.count) settings · \(source.history.activeTranscripts) active · \(source.history.archivedTranscripts) archived"
                    ).font(AIMTheme.mono(10)).foregroundStyle(AIMTheme.muted)
                  }
                  Spacer()
                  Badge(
                    text: source.support.label,
                    color: source.support == .supportedChatGPT ? AIMTheme.green : AIMTheme.amber)
                }.padding(.horizontal, 16).frame(minHeight: 58).background(
                  source.id == model.selectedSourceID
                    ? AIMTheme.active.opacity(0.70)
                    : (hoveredSourceID == source.id
                      ? AIMTheme.panel2
                      : (index.isMultiple(of: 2) ? .clear : AIMTheme.panel2.opacity(0.55)))
                ).contentShape(Rectangle())
                  .foregroundStyle(
                    source.id == model.selectedSourceID ? AIMTheme.activeInk : AIMTheme.ink)
                  .opacity(isEnabled ? 1 : 0.55)
              }.buttonStyle(AIMPressButtonStyle())
                .onHover { hoveredSourceID = $0 && isEnabled ? source.id : nil }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: hoveredSourceID)
                .animation(
                  reduceMotion ? nil : .easeOut(duration: 0.10), value: model.selectedSourceID)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isEnabled)
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
          ? "Imports credentials and links the existing shared settings and history. The source stays unchanged."
          : "Reviews shared settings conflicts and adds source chats to the merged library. Everything affected is backed up first."
      ).font(AIMTheme.sans(11)).foregroundStyle(AIMTheme.muted).frame(
        maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 4) {
        AIMButton(title: "Choose other…", icon: .folder) { Task { await model.chooseSource() } }
        AIMButton(title: "Refresh", icon: .refresh) { Task { await model.discover() } }
        Spacer()
        AIMButton(
          title: "Review import", tone: .primary,
          disabled: model.selectedSourceID == nil
            || model.discoveries.first(where: { $0.id == model.selectedSourceID })?.support
              != .supportedChatGPT
        ) { Task { await model.reviewImport() } }
      }
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.top, 12).padding(.bottom, 24).frame(
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
        ZStack {
          Rectangle().stroke(selected ? AIMTheme.activeInk : AIMTheme.ink.opacity(0.35))
          if selected { AIMIcon(name: .check, size: 10) }
        }.frame(width: 14, height: 14)
        Text(title)
      }.font(AIMTheme.sans(11, weight: .medium)).padding(.horizontal, 10).frame(height: 30)
        .foregroundStyle(
          !isEnabled ? AIMTheme.disabledInk : (selected ? AIMTheme.activeInk : AIMTheme.ink)
        ).background(
          !isEnabled
            ? AIMTheme.disabledControl
            : (selected ? AIMTheme.active : (hover ? AIMTheme.controlHover : AIMTheme.control)))
    }.buttonStyle(AIMPressButtonStyle()).accessibilityAddTraits(selected ? .isSelected : [])
      .onHover { hover = $0 && isEnabled }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: hover)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: selected)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isEnabled)
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
    VStack(spacing: 8) {
      AIMScrollView {
        VStack(spacing: 8) {
          AIMPanel(title: "Plan") {
            VStack(spacing: 0) {
              DetailRow(label: "Account", value: plan.identity.displayName)
              DetailRow(label: "Destination", value: plan.destination.path, zebra: true)
              DetailRow(label: "Backup", value: plan.backup.path)
              DetailRow(
                label: "Space needed",
                value: ByteCountFormatter.string(
                  fromByteCount: plan.requiredBytes, countStyle: .file), zebra: true)
            }
          }
          if !plan.warnings.isEmpty {
            AIMPanel(title: "Warnings") {
              VStack(spacing: 0) {
                ForEach(plan.warnings, id: \.self) { Notice(text: $0, tone: AIMTheme.amber) }
              }
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
                        ? "This settings choice affects every linked account."
                        : "The managed credential differs from this source."
                    ).font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
                    HStack(spacing: 4) {
                      Choice(
                        title: conflict.affectsAllAccounts ? "Keep shared" : "Keep managed",
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
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.top, 12).padding(.bottom, 24)
  }
}
private struct ImportResultPage: View {
  let result: ImportResult
  @ObservedObject var model: AccountViewModel
  var body: some View {
    VStack(spacing: 8) {
      AIMScrollView {
        VStack(spacing: 8) {
          AIMPanel(title: result.unresolved.isEmpty ? "Import complete" : "Review required") {
            HStack(spacing: 14) {
              ZStack {
                AIMTheme.green
                AIMIcon(name: result.unresolved.isEmpty ? .check : .warning, size: 24)
                  .foregroundStyle(AIMTheme.activeInk)
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
              DetailRow(label: "Profile", value: result.account.home.path)
              DetailRow(label: "Backup", value: result.backup.path, zebra: true)
              DetailRow(
                label: "Imported",
                value: "\(result.importedFiles) files and \(result.importedChats) chats")
            }
          }
          if !result.unresolved.isEmpty {
            AIMPanel(title: "Unresolved items") {
              VStack(spacing: 0) {
                ForEach(result.unresolved, id: \.self) { Notice(text: $0, tone: AIMTheme.amber) }
              }
            }
          }
          Notice(
            text:
              "The imported account is ready. Choose Use for new Codex sessions when you want to switch.",
            tone: AIMTheme.blue)
        }
      }
      HStack {
        Spacer()
        AIMButton(title: "Done", tone: .primary) {
          model.resetImport()
          model.showImport = false
        }
      }
    }.padding(.horizontal, AIMTheme.modalOuterInset).padding(.top, 12).padding(.bottom, 24)
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
