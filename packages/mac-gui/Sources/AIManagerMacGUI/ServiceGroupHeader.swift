import AIManagerCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ServiceGroupHeader: View, Equatable {
  let provider: ProviderID
  let providers: [ProviderID]
  let showsInTray: Bool
  var count: Int? = nil
  var canReorder = true
  @State private var hovered = false
  @FocusState private var eyeFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(provider.guiName)
    .accessibilityAddTraits(.isHeader)
    .contextMenu {
      Button(help) { MenuBarServicePreferences.toggleVisibility(provider) }
      if canReorder, let index = order.firstIndex(of: provider) {
        Button("Move service up") { move(to: order[index - 1]) }.disabled(index == 0)
        Button("Move service down") { move(to: order[index + 1]) }.disabled(index == order.count - 1)
      }
    }
    .modifier(ServiceHeaderDrag(provider: provider, enabled: canReorder))
  }

  private func move(to target: ProviderID) {
    MenuBarServicePreferences.move(provider, to: target, in: providers)
  }
}

@MainActor
enum ServiceReorderDrag {
  static var source: ProviderID?
  private static var endTask: Task<Void, Never>?

  static func begin(_ provider: ProviderID) -> NSItemProvider {
    end()
    source = provider
    // SwiftUI onDrag has no end callback on macOS 14, including a cancelled drag outside the app.
    // shortcut: drag identity expires after two minutes; use a drag-session callback when macOS 14 support ends.
    endTask = Task { @MainActor in
      for _ in 0..<1200 {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        if NSEvent.pressedMouseButtons & 1 == 0 || CGEventSource.keyState(.combinedSessionState, key: 53) { break }
      }
      end()
    }
    return NSItemProvider(object: provider.rawValue as NSString)
  }

  static func end() {
    source = nil
    endTask?.cancel()
    endTask = nil
  }
}

private struct ServiceHeaderDrag: ViewModifier {
  let provider: ProviderID
  let enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.onDrag { ServiceReorderDrag.begin(provider) }
    } else { content }
  }
}

struct ServiceGroupDrop: ViewModifier {
  let provider: ProviderID
  let providers: [ProviderID]
  var enabled = true
  let onMove: ([ProviderID]) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    if enabled {
      content.contentShape(Rectangle()).onDrop(of: [.text], delegate: ServiceReorderDropDelegate(
        provider: provider, providers: providers, reduceMotion: reduceMotion, onMove: onMove))
    } else { content }
  }
}

struct ServiceReorderDropDelegate: DropDelegate {
  let provider: ProviderID
  let providers: [ProviderID]
  var reduceMotion = false
  var defaults: UserDefaults = .standard
  var onMove: ([ProviderID]) -> Void = { _ in }

  private var acceptsSource: Bool {
    guard let source = ServiceReorderDrag.source else { return false }
    return providers.contains(source) && providers.contains(provider)
  }

  func validateDrop(info: DropInfo) -> Bool { acceptsSource }
  func dropEntered(info: DropInfo) { dropEntered() }
  func dropUpdated(info: DropInfo) -> DropProposal? { dropUpdated() }
  func performDrop(info: DropInfo) -> Bool { performDrop() }

  // DropInfo has no public initializer; these entry points also drive the contract check.
  func dropEntered() {
    guard acceptsSource, let source = ServiceReorderDrag.source, source != provider else { return }
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
      MenuBarServicePreferences.move(source, to: provider, in: providers, defaults: defaults)
      onMove(MenuBarServicePreferences.order(defaults: defaults))
    }
  }

  func dropUpdated() -> DropProposal? { DropProposal(operation: acceptsSource ? .move : .cancel) }

  func performDrop() -> Bool {
    let accepted = acceptsSource
    ServiceReorderDrag.end()
    return accepted
  }
}
