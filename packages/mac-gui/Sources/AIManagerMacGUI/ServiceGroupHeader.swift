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
  @State private var targeted = false
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
    .modifier(ServiceHeaderDrag(provider: provider, providers: providers, enabled: canReorder, targeted: $targeted))
    .overlay(alignment: ServiceReorderDrag.edge(for: provider, in: order) == .top ? .top : .bottom) {
      if targeted, ServiceReorderDrag.source != provider {
        Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
      }
    }
  }

  private func move(to target: ProviderID) {
    MenuBarServicePreferences.move(provider, to: target, in: providers)
  }
}

@MainActor
private enum ServiceReorderDrag {
  static let type = UTType(exportedAs: "com.mandalsuraj.switch.service-order")
  static var source: ProviderID?

  static func edge(for target: ProviderID, in providers: [ProviderID]) -> VerticalEdge {
    guard let source, let from = providers.firstIndex(of: source), let to = providers.firstIndex(of: target)
    else { return .top }
    return from > to ? .top : .bottom
  }
}

private struct ServiceHeaderDrag: ViewModifier {
  let provider: ProviderID
  let providers: [ProviderID]
  let enabled: Bool
  @Binding var targeted: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.onDrag {
        ServiceReorderDrag.source = provider
        return NSItemProvider(item: Data(provider.rawValue.utf8) as NSData,
          typeIdentifier: ServiceReorderDrag.type.identifier)
      }
      .onDrop(of: [ServiceReorderDrag.type], isTargeted: $targeted) { items in
        let source = ServiceReorderDrag.source
        ServiceReorderDrag.source = nil
        guard let source, source != provider, providers.contains(source),
              let item = items.first else { return false }
        item.loadDataRepresentation(forTypeIdentifier: ServiceReorderDrag.type.identifier) { data, _ in
          guard data == Data(source.rawValue.utf8) else { return }
          Task { @MainActor in MenuBarServicePreferences.move(source, to: provider, in: providers) }
        }
        return true
      }
    } else { content }
  }
}
