import AppKit
import SwiftUI

private struct AIMFocusIndicatorsKey: EnvironmentKey {
  static let defaultValue = false
}

private struct AIMDarkModeKey: EnvironmentKey {
  static let defaultValue = false
}

private struct AIMAdaptiveColor: ShapeStyle, Hashable {
  let light: UInt32
  let dark: UInt32

  func resolve(in environment: EnvironmentValues) -> Color.Resolved {
    return Color(hex: environment.colorScheme == .dark ? dark : light).resolve(in: environment)
  }
}

extension EnvironmentValues {
  var aimFocusIndicatorsEnabled: Bool {
    get { self[AIMFocusIndicatorsKey.self] }
    set { self[AIMFocusIndicatorsKey.self] = newValue }
  }

  var aimDarkMode: Bool {
    get { self[AIMDarkModeKey.self] }
    set { self[AIMDarkModeKey.self] = newValue }
  }
}

enum AIMTheme {
  static let radius: CGFloat = 3
  static let railWidth: CGFloat = 48
  static let topbarHeight: CGFloat = 56
  static let listWidth: CGFloat = 200
  static let windowControlSize: CGFloat = 48
  static let modalOuterInset: CGFloat = 24
  static let panelContentInset: CGFloat = 16

  static let canvas = dynamic(light: 0xECEBE7, dark: 0x0B0C0F)
  static let rail = dynamic(light: 0xF4F3EF, dark: 0x101216)
  static let panel = dynamic(light: 0xFAF9F6, dark: 0x17191D)
  static let panel2 = dynamic(light: 0xF0EFEB, dark: 0x1D2025)
  static let panel3 = dynamic(light: 0xE5E4DF, dark: 0x262A30)
  static let line = dynamic(light: 0xD4D3CE, dark: 0x2A2E34)
  static let lineSoft = dynamic(light: 0xE2E1DC, dark: 0x22262B)
  static let ink = dynamic(light: 0x1A1B1D, dark: 0xEFEEE9)
  static let muted = dynamic(light: 0x666970, dark: 0x999CA3)
  static let faint = dynamic(light: 0x75787F, dark: 0x767A82)
  static let blue = dynamic(light: 0x566D95, dark: 0x8295B5)
  static let green = dynamic(light: 0x557D68, dark: 0x78A28B)
  static let amber = dynamic(light: 0x856F43, dark: 0xB39A68)
  static let red = dynamic(light: 0x8D5A60, dark: 0xAD7379)
  static let titleArt = dynamic(light: 0x657B98, dark: 0x92A7C3)
  static let active = dynamic(light: 0xDCE3EC, dark: 0x3C4A61)
  static let activeInk = dynamic(light: 0x28364A, dark: 0xF2F1ED)
  static let railIdle = dynamic(light: 0x5D6670, dark: 0x91A0B2)
  static let statusInk = dynamic(light: 0xFFFFFF, dark: 0x0B0C0F)
  static let control = dynamic(light: 0xDEDCD6, dark: 0x1D2025)
  static let controlHover = dynamic(light: 0xD3D1CA, dark: 0x262A30)
  static let disabledControl = dynamic(light: 0xE5E4DF, dark: 0x1A1C20)
  static let disabledInk = dynamic(light: 0x74777D, dark: 0x858890)

  static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom("Geist-Regular", size: size).weight(weight)
  }

  static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom("GeistMono-Regular", size: size).weight(weight)
  }

  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(AIMAdaptiveColor(light: light, dark: dark))
  }
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255,
      opacity: 1
    )
  }
}

struct AIMIcon: View {
  enum Name: CaseIterable {
    case mark, account, settings, history, recovery, plus, refresh, moon, sun, close, minimize
    case chevron, check, folder, play, copy, warning

    var symbol: String {
      switch self {
      case .mark: "play.rectangle"
      case .account: "person.crop.circle"
      case .settings: "gearshape"
      case .history: "clock.arrow.circlepath"
      case .recovery: "arrow.counterclockwise"
      case .plus: "plus"
      case .refresh: "arrow.clockwise"
      case .moon: "moon"
      case .sun: "sun.max"
      case .close: "xmark"
      case .minimize: "minus"
      case .chevron: "chevron.right"
      case .check: "checkmark"
      case .folder: "folder"
      case .play: "play"
      case .copy: "doc.on.doc"
      case .warning: "exclamationmark.triangle"
      }
    }
  }

  let name: Name
  var size: CGFloat = 17

  @ViewBuilder
  var body: some View {
    if name == .mark, let mark = AIManagerBrand.railMark() {
      Image(nsImage: mark)
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    } else {
      Image(systemName: name.symbol)
        .font(.system(size: size, weight: .regular))
        .symbolRenderingMode(.monochrome)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }
}

struct AIMPressButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> Body {
    Body(configuration: configuration)
  }

  struct Body: View {
    let configuration: Configuration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.aimFocusIndicatorsEnabled) private var focusIndicatorsEnabled
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
        .opacity(configuration.isPressed ? 0.84 : (isHovered ? 0.94 : 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .focusEffectDisabled(!focusIndicatorsEnabled)
        .onHover { isHovered = $0 }
    }
  }
}

struct AIMPanel<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Text(title)
          .font(AIMTheme.sans(12, weight: .semibold))
          .padding(.horizontal, AIMTheme.panelContentInset)
          .frame(height: 40)
        Spacer(minLength: 0)
      }
      .frame(height: 40)
      .background {
        LinearGradient(
          colors: [AIMTheme.green.opacity(0.10), .clear, AIMTheme.titleArt.opacity(0.14)],
          startPoint: .leading,
          endPoint: .trailing
        )
        .allowsHitTesting(false)
      }
      .background(AIMTheme.panel2)
      content
    }
    .background(AIMTheme.panel)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }
}

struct AIMScrollView<Content: View>: View {
  @ViewBuilder let content: Content
  @Environment(\.aimDarkMode) private var darkMode
  @Environment(\.aimFocusIndicatorsEnabled) private var focusIndicatorsEnabled

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    AIMNativeScrollView(
      content: AnyView(
        content.environment(\.colorScheme, darkMode ? .dark : .light)
          .environment(\.aimDarkMode, darkMode)
          .environment(\.aimFocusIndicatorsEnabled, focusIndicatorsEnabled)
          .foregroundStyle(AIMTheme.ink)
          .focusEffectDisabled(!focusIndicatorsEnabled)))
  }
}

final class AIMThinScroller: NSScroller {
  override class var isCompatibleWithOverlayScrollers: Bool { true }
  override var scrollerStyle: NSScroller.Style {
    get { super.scrollerStyle }
    set { super.scrollerStyle = .overlay }
  }

  override class func scrollerWidth(
    for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style
  ) -> CGFloat { 3 }

  override func drawKnob() {
    let knob = rect(for: .knob)
    guard !knob.isEmpty else { return }
    NSColor.secondaryLabelColor.withAlphaComponent(0.52).setFill()
    NSBezierPath(
      roundedRect: NSRect(x: bounds.midX - 1.5, y: knob.minY, width: 3, height: knob.height),
      xRadius: 1.5,
      yRadius: 1.5
    ).fill()
  }

  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

final class AIMOwnedScrollView: NSScrollView {
  private var hideTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovered = false
  private var isScrolling = false
  private var isScrollerVisible = false

  override var scrollerStyle: NSScroller.Style {
    get { super.scrollerStyle }
    set { super.scrollerStyle = .overlay }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = false
    borderType = .noBorder
    hasHorizontalScroller = false
    hasVerticalScroller = true
    autohidesScrollers = true
    verticalScroller = AIMThinScroller()
    super.scrollerStyle = .overlay
    verticalScroller?.scrollerStyle = .overlay
    verticalScroller?.controlSize = .mini
    verticalScroller?.wantsLayer = true
    verticalScroller?.alphaValue = 0
    observers = [
      NotificationCenter.default.addObserver(
        forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: .main
      ) { [weak self] _ in
        self?.isScrolling = true
        self?.showScroller()
      },
      NotificationCenter.default.addObserver(
        forName: NSScrollView.didEndLiveScrollNotification, object: self, queue: .main
      ) { [weak self] _ in
        self?.isScrolling = false
        self?.scheduleHide()
      },
    ]
  }

  @available(*, unavailable) required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
      userInfo: nil)
    addTrackingArea(trackingArea)
    hoverTrackingArea = trackingArea
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    documentView?.appearance = effectiveAppearance
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    documentView?.appearance = effectiveAppearance
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    showScroller()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    scheduleHide()
  }

  override func scrollWheel(with event: NSEvent) {
    showScroller()
    super.scrollWheel(with: event)
    if event.phase == .ended || event.phase == [] { scheduleHide() }
  }

  private func showScroller() {
    hideTask?.cancel()
    setScrollerVisible(true)
  }

  private func scheduleHide() {
    guard !isHovered, !isScrolling else { return }
    hideTask?.cancel()
    hideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      self?.setScrollerVisible(false)
    }
  }

  private func setScrollerVisible(_ visible: Bool) {
    guard visible != isScrollerVisible, let scroller = verticalScroller else { return }
    isScrollerVisible = visible
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ? 0 : (visible ? 0.12 : 0.20)
      scroller.animator().alphaValue = visible ? 1 : 0
    }
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    hideTask?.cancel()
  }
}

private struct AIMNativeScrollView: NSViewRepresentable {
  let content: AnyView

  final class Coordinator {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> AIMOwnedScrollView {
    let scrollView = AIMOwnedScrollView(frame: .zero)
    let host = context.coordinator.host
    host.translatesAutoresizingMaskIntoConstraints = false
    host.focusRingType = .none
    host.rootView = content
    scrollView.documentView = host
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
      host.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
      host.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
    ])
    return scrollView
  }

  func updateNSView(_ scrollView: AIMOwnedScrollView, context: Context) {
    context.coordinator.host.rootView = content
    context.coordinator.host.appearance = scrollView.effectiveAppearance
  }
}
