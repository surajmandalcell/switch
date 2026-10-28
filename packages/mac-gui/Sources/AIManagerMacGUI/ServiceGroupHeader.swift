import AIManagerCore
import AppKit
import SwiftUI

struct ServiceGroupHeader: View, Equatable {
  let provider: ProviderID
  let providers: [ProviderID]
  let showsInTray: Bool
  var count: Int? = nil
  var canReorder = true
  @State private var hovered = false
  @FocusState private var eyeFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(ServiceReorderState.self) private var reorder

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.provider == rhs.provider && lhs.providers == rhs.providers && lhs.showsInTray == rhs.showsInTray
      && lhs.count == rhs.count && lhs.canReorder == rhs.canReorder
  }

  private var order: [ProviderID] { MenuBarServicePreferences.orderedProviders(providers) }
  private var help: String { showsInTray ? "Hide from menu bar" : "Show in menu bar" }

  var body: some View {
    HStack(spacing: 8) {
      ProviderMark(providerID: provider, size: 16)
      Text(provider.guiName)
        .aimText(.secondary, tint: count == nil ? MenuBarPresentation.secondaryInk : .primary)
        .fontWeight(.semibold).lineLimit(1)
        .help(provider.guiName)
        .uiLint(.align(count == nil ? "menuBarGroupHeaderInk" : "accountGroupHeaderInk", .start))
      if let count {
        Text("×\(count)").aimText(.secondary).monospacedDigit().layoutPriority(1)
      }
      Spacer(minLength: 0)
      Button {
        MenuBarServicePreferences.toggleVisibility(provider)
      } label: {
        Image(systemName: showsInTray ? "eye" : "eye.slash")
          .aimText(.secondary)
          .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focused($eyeFocused)
      .focusEffectDisabled()
      .foregroundStyle(.secondary)
      .opacity(hovered || eyeFocused ? 1 : showsInTray ? 0 : 0.5)
      .animation(.easeOut(duration: 0.18), value: hovered || eyeFocused)
      .animation(.easeOut(duration: 0.18), value: showsInTray)
      .help(help)
      .accessibilityLabel("\(help): \(provider.guiName)")
      .accessibilityIdentifier("service-eye-\(provider.rawValue)")
      .serviceInteractionFrame("service-eye-\(provider.rawValue)")
    }
    .contentShape(Rectangle())
    .background(ServiceHeaderHover(provider: provider, hovered: $hovered))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(provider.guiName)
    .accessibilityIdentifier("service-header-\(provider.rawValue)")
    .accessibilityAddTraits(.isHeader)
    .contextMenu {
      Button(help) { MenuBarServicePreferences.toggleVisibility(provider) }
      if canReorder, let index = order.firstIndex(of: provider) {
        Button("Move service up") { move(to: order[index - 1]) }.disabled(index == 0)
        Button("Move service down") { move(to: order[index + 1]) }.disabled(index == order.count - 1)
      }
    }
    .modifier(ServiceHeaderDrag(provider: provider, providers: providers, enabled: canReorder))
  }

  private func move(to target: ProviderID) {
    MenuBarServicePreferences.move(provider, to: target, in: providers)
    reorder.order = MenuBarServicePreferences.order()
  }
}

/// Track inactive windows too, without making the header a mouse or keyboard target.
private struct ServiceHeaderHover: NSViewRepresentable {
  let provider: ProviderID
  @Binding var hovered: Bool

  final class HoverView: NSView {
    var changed: (Bool) -> Void = { _ in }
    private var hoverArea: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let hoverArea { removeTrackingArea(hoverArea) }
      let area = NSTrackingArea(rect: .zero,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area)
      hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { changed(true) }
    override func mouseExited(with event: NSEvent) { changed(false) }
  }

  func makeNSView(context: Context) -> HoverView {
    let view = HoverView()
    view.identifier = NSUserInterfaceItemIdentifier("service-header-\(provider.rawValue)")
    view.setAccessibilityElement(false)
    return view
  }
  func updateNSView(_ view: HoverView, context: Context) { view.changed = { hovered = $0 } }
}

extension View {
  @ViewBuilder fileprivate func serviceInteractionFrame(_ id: String) -> some View {
    #if AI_MANAGER_PREVIEW
    if CommandLine.arguments.contains("--service-interaction-only") {
      background(ServiceInteractionFrame(id: id))
    } else { self }
    #else
    self
    #endif
  }
}

#if AI_MANAGER_PREVIEW
private struct ServiceInteractionFrame: NSViewRepresentable {
  let id: String
  final class FrameView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
  func makeNSView(context: Context) -> FrameView {
    let view = FrameView()
    view.identifier = NSUserInterfaceItemIdentifier(id)
    return view
  }
  func updateNSView(_ view: FrameView, context: Context) {}
}
#endif

@MainActor @Observable final class ServiceReorderState {
  var source: ProviderID?
  var order: [ProviderID] = []
  var frames: [ProviderID: CGRect] = [:]
  private var originalOrder: [ProviderID] = []
  private var originalFrames: [ProviderID: CGRect] = [:]
  private var translation: CGFloat = 0

  func update(_ provider: ProviderID, translation: CGFloat, providers: [ProviderID],
              reduceMotion: Bool, defaults: UserDefaults = .standard) {
    guard providers.contains(provider), frames[provider] != nil else { return }
    if source == nil {
      originalOrder = MenuBarServicePreferences.orderedProviders(providers, defaults: defaults)
      originalFrames = frames
      order = originalOrder
      source = provider
    }
    guard source == provider, let frame = originalFrames[provider],
      let from = originalOrder.firstIndex(of: provider) else { return }
    self.translation = translation
    let position = frame.minY + translation
    var to = from
    for (index, candidate) in originalOrder.enumerated() {
      guard let target = originalFrames[candidate] else { continue }
      if translation > 0 && index > from && position > target.minY { to = index }
      if translation < 0 && index < from && position < target.minY { to = min(to, index) }
    }
    var next = originalOrder
    next.remove(at: from)
    next.insert(provider, at: to)
    if next != order {
      withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.85)) { order = next }
    }
  }

  func offset(_ provider: ProviderID) -> CGFloat {
    guard source == provider, let start = originalFrames[provider], let current = frames[provider] else { return 0 }
    return start.minY + translation - current.minY
  }

  func end(reduceMotion: Bool, defaults: UserDefaults = .standard) {
    guard let source, let to = order.firstIndex(of: source), originalOrder.indices.contains(to) else { return }
    MenuBarServicePreferences.move(source, to: originalOrder[to], in: originalOrder, defaults: defaults)
    withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.85)) {
      self.source = nil
      translation = 0
    }
  }

  func cancel() {
    if source != nil { order = originalOrder }
    source = nil
    translation = 0
  }
}

private struct ServiceHeaderDrag: ViewModifier {
  let provider: ProviderID
  let providers: [ProviderID]
  let enabled: Bool
  @Environment(ServiceReorderState.self) private var reorder
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @GestureState private var dragging = false

  func body(content: Content) -> some View {
    if enabled {
      content.gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
        .updating($dragging) { _, dragging, _ in dragging = true }
        .onChanged { reorder.update(provider, translation: $0.translation.height,
          providers: providers, reduceMotion: reduceMotion) }
        .onEnded { _ in reorder.end(reduceMotion: reduceMotion) })
      .onChange(of: dragging) { _, active in if !active { reorder.cancel() } }
      .accessibilityAction(named: Text("Move up")) { move(-1) }
      .accessibilityAction(named: Text("Move down")) { move(1) }
    } else { content }
  }

  private func move(_ step: Int) {
    let order = MenuBarServicePreferences.orderedProviders(providers)
    guard let index = order.firstIndex(of: provider), order.indices.contains(index + step) else { return }
    MenuBarServicePreferences.move(provider, to: order[index + step], in: providers)
    reorder.order = MenuBarServicePreferences.order()
  }
}

struct ServiceGroupReorder: ViewModifier {
  let provider: ProviderID
  let leadingInset: CGFloat
  @Environment(ServiceReorderState.self) private var reorder

  func body(content: Content) -> some View {
    content
      .offset(y: reorder.offset(provider))
      .transaction { if reorder.source == provider { $0.animation = nil } }
      .background(GeometryReader { geometry in
        let group = geometry.frame(in: .global)
        let frame = CGRect(x: group.minX, y: group.minY + leadingInset,
          width: group.width, height: group.height - leadingInset)
        Color.clear
          .onAppear { reorder.frames[provider] = frame }
          .onChange(of: frame) { _, frame in reorder.frames[provider] = frame }
      })
      .zIndex(reorder.source == provider ? 1 : 0)
      .onDisappear {
        reorder.frames.removeValue(forKey: provider)
        if reorder.source == provider { reorder.cancel() }
      }
  }
}
