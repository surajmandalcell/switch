import AppKit
import SwiftUI

struct MenuBarUsageSnapshot: Equatable, Sendable {
  let usedPercentage: Int?
  let secondaryUsedPercentage: Int?
  let resetDescription: String?
  let secondaryResetDescription: String?
  let fetchedAt: Date?

  init(
    usedPercentage: Int?,
    secondaryUsedPercentage: Int? = nil,
    resetDescription: String? = nil,
    secondaryResetDescription: String? = nil,
    fetchedAt: Date? = nil
  ) {
    self.usedPercentage = usedPercentage.map { min(max($0, 0), 100) }
    self.secondaryUsedPercentage = secondaryUsedPercentage.map { min(max($0, 0), 100) }
    self.resetDescription = resetDescription
    self.secondaryResetDescription = secondaryResetDescription
    self.fetchedAt = fetchedAt
  }

}

struct MenuBarAccountSnapshot: Identifiable, Equatable, Sendable {
  let id: UUID
  let identity: String
  let detail: String
  let isVerified: Bool
  let isActive: Bool
  let usage: MenuBarUsageSnapshot?
  let showsUsage: Bool

  init(
    id: UUID,
    identity: String,
    detail: String,
    isVerified: Bool,
    isActive: Bool,
    usage: MenuBarUsageSnapshot? = nil,
    showsUsage: Bool = true
  ) {
    self.id = id
    self.identity = identity
    self.detail = detail
    self.isVerified = isVerified
    self.isActive = isActive
    self.usage = showsUsage ? usage : nil
    self.showsUsage = showsUsage
  }
}

struct MenuBarSnapshot: Equatable, Sendable {
  let accounts: [MenuBarAccountSnapshot]
  let primaryUsedPercentage: Int?
  let lastRefreshedAt: Date?

  static let empty = MenuBarSnapshot(
    accounts: [], primaryUsedPercentage: nil, lastRefreshedAt: nil)

  init(
    accounts: [MenuBarAccountSnapshot], primaryUsedPercentage: Int?,
    lastRefreshedAt: Date? = nil
  ) {
    self.accounts = accounts
    self.primaryUsedPercentage = primaryUsedPercentage.map { min(max($0, 0), 100) }
    self.lastRefreshedAt = lastRefreshedAt ?? accounts.compactMap(\.usage?.fetchedAt).max()
  }
}

@MainActor
struct MenuBarPopoverActions {
  let openMainWindow: () -> Void
  let switchAccount: (UUID) async throws -> Void
  let copyText: ((String) -> Void)?

  init(
    openMainWindow: @escaping () -> Void,
    switchAccount: @escaping (UUID) async throws -> Void,
    copyText: ((String) -> Void)? = nil
  ) {
    self.openMainWindow = openMainWindow
    self.switchAccount = switchAccount
    self.copyText = copyText
  }
}

@MainActor
final class MenuBarPopoverStore: ObservableObject {
  @Published private(set) var snapshot: MenuBarSnapshot
  @Published private(set) var switchingAccountID: UUID?
  @Published private(set) var rowErrors: [UUID: String] = [:]

  let actions: MenuBarPopoverActions
  var didSwitch: (() -> Void)?
  var didRequestDismissal: (() -> Void)?

  init(snapshot: MenuBarSnapshot, actions: MenuBarPopoverActions) {
    self.snapshot = snapshot
    self.actions = actions
  }

  func update(snapshot: MenuBarSnapshot) {
    self.snapshot = snapshot
    rowErrors = rowErrors.filter { error in
      snapshot.accounts.contains { $0.id == error.key }
    }
  }

  func openMainWindow() {
    actions.openMainWindow()
    didRequestDismissal?()
  }

  func copyError(_ error: String) {
    if let copyText = actions.copyText {
      copyText(error)
      return
    }
    #if !AI_MANAGER_PREVIEW
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(error, forType: .string)
    #endif
  }

  func select(_ account: MenuBarAccountSnapshot) {
    guard switchingAccountID == nil, account.isVerified,
      !account.isActive
    else { return }

    switchingAccountID = account.id
    rowErrors[account.id] = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await actions.switchAccount(account.id)
        switchingAccountID = nil
        didSwitch?()
      } catch {
        switchingAccountID = nil
        rowErrors[account.id] = error.localizedDescription
      }
    }
  }

}

struct MenuBarPopover: View {
  static let width: CGFloat = 384
  static let minimumHeight: CGFloat = 124
  static let maximumHeight: CGFloat = 440
  static let footerHeight: CGFloat = 48
  static let listInset: CGFloat = 10
  static let cardSpacing: CGFloat = 8
  static let accountHeaderHeight: CGFloat = 58
  static let quotaRowHeight: CGFloat = 44
  static let accountActionWidth: CGFloat = 64
  static let accountActionHeight: CGFloat = 24

  static func accountRowHeight(_ account: MenuBarAccountSnapshot) -> CGFloat {
    let quotaCount = [account.usage?.secondaryUsedPercentage, account.usage?.usedPercentage]
      .compactMap { $0 }.count
    guard account.showsUsage, quotaCount > 0 else { return accountHeaderHeight }
    return accountHeaderHeight + 25 + CGFloat(quotaCount) * quotaRowHeight
      + CGFloat(max(0, quotaCount - 1)) * 10
  }

  @ObservedObject var store: MenuBarPopoverStore
  @AppStorage("keyboardFocusIndicators") private var showFocusIndicators = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      accountList
      footer
    }
    .frame(width: Self.width)
    .background {
      LinearGradient(
        colors: [AIMTheme.panel, AIMTheme.menuChrome],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)
    }
    .foregroundStyle(AIMTheme.ink)
    .environment(\.aimDarkMode, colorScheme == .dark)
    .environment(\.aimFocusIndicatorsEnabled, showFocusIndicators)
    .focusEffectDisabled(!showFocusIndicators)
    .overlay {
      RoundedRectangle(cornerRadius: AIMTheme.radius)
        .stroke(AIMTheme.lineSoft, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }

  @ViewBuilder
  private var accountList: some View {
    if store.snapshot.accounts.isEmpty {
      VStack(spacing: 4) {
        Text("No accounts yet")
          .font(AIMTheme.sans(14, weight: .semibold))
        Text("Open the app to add an account.")
          .font(AIMTheme.sans(11))
          .foregroundStyle(AIMTheme.muted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    } else {
      AIMVirtualList(
        items: store.snapshot.accounts,
        rowSpacing: Self.cardSpacing,
        contentRevision: rowContentRevision
      ) { account in
        return AnyView(
          MenuBarAccountRow(
            account: account,
            isSwitching: store.switchingAccountID == account.id,
            error: store.rowErrors[account.id],
            copyError: { store.copyError($0) },
            action: { store.select(account) }
          )
          .padding(.horizontal, Self.listInset)
        )
      }
      .padding(.vertical, Self.listInset)
    }
  }

  private var rowContentRevision: Int {
    var hasher = Hasher()
    hasher.combine(store.switchingAccountID)
    for (id, error) in store.rowErrors.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      hasher.combine(id)
      hasher.combine(error)
    }
    return hasher.finalize()
  }

  private var footer: some View {
    HStack(spacing: 12) {
      if let refreshedAt = store.snapshot.lastRefreshedAt {
        Text("Refreshed \(refreshedAt.formatted(.relative(presentation: .numeric)))")
          .font(AIMTheme.sans(10))
          .foregroundStyle(AIMTheme.muted)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      MenuBarHoverButton(action: store.openMainWindow) {
        HStack(spacing: 7) {
          AIMIcon(name: .openApp, size: 13)
          Text("Open App")
        }
        .font(AIMTheme.sans(11, weight: .semibold))
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
      }
    }
    .padding(.leading, 14)
    .frame(height: Self.footerHeight)
    .background(AIMTheme.menuChrome)
    .overlay(alignment: .top) { Divider().overlay(AIMTheme.lineSoft) }
  }
}

private struct MenuBarAccountRow: View {
  let account: MenuBarAccountSnapshot
  let isSwitching: Bool
  let error: String?
  let copyError: (String) -> Void
  let action: () -> Void

  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Circle()
          .fill(account.isActive ? AIMTheme.green : (account.isVerified ? AIMTheme.faint : AIMTheme.amber))
          .frame(width: 9, height: 9)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(account.identity)
            .font(AIMTheme.sans(13, weight: .semibold))
            .lineLimit(1)
          Text(error ?? account.detail)
            .font(AIMTheme.sans(10))
            .foregroundStyle(error == nil ? AIMTheme.muted : AIMTheme.red)
            .lineLimit(1)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let error {
          Button { copyError(error) } label: {
            AIMIcon(name: .copy, size: 12)
              .foregroundStyle(AIMTheme.amber)
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(AIMPressButtonStyle())
          .help("Copy error")
          .accessibilityLabel("Copy account error")
        }
        switchControl
      }
      .padding(.horizontal, 14)
      .frame(height: MenuBarPopover.accountHeaderHeight)

      if let usage = account.usage, account.showsUsage,
         usage.usedPercentage != nil || usage.secondaryUsedPercentage != nil
      {
        Rectangle().fill(AIMTheme.lineSoft).frame(height: 1)
        VStack(spacing: 10) {
          if let percentage = usage.secondaryUsedPercentage {
            MenuBarQuotaRow(
              label: "Weekly", percentage: percentage,
              reset: usage.secondaryResetDescription, color: AIMTheme.green)
          }
          if let percentage = usage.usedPercentage {
            MenuBarQuotaRow(
              label: "5 hour", percentage: percentage,
              reset: usage.resetDescription, color: AIMTheme.blue)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
      }
    }
    .frame(height: MenuBarPopover.accountRowHeight(account))
    .background(cardBackground)
    .overlay {
      RoundedRectangle(cornerRadius: AIMTheme.radius)
        .stroke(AIMTheme.lineSoft, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
    .onHover { hovered in
      withAnimation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover)) {
        isHovered = hovered
      }
    }
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(
      account.isActive
        ? "Active account"
        : account.isVerified ? "Use for new Codex sessions" : "Open the app to sign in")
  }

  @ViewBuilder private var switchControl: some View {
    if isSwitching {
      ProgressView()
        .controlSize(.small)
        .frame(width: MenuBarPopover.accountActionWidth, height: MenuBarPopover.accountActionHeight)
        .background(AIMTheme.control.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
        .accessibilityLabel("Switching account")
    } else if account.isActive {
      Text("Active")
        .font(AIMTheme.sans(10, weight: .medium))
        .foregroundStyle(AIMTheme.green)
        .frame(
          width: MenuBarPopover.accountActionWidth,
          height: MenuBarPopover.accountActionHeight)
        .background(AIMTheme.green.opacity(0.08))
        .overlay {
          RoundedRectangle(cornerRadius: AIMTheme.radius)
            .stroke(AIMTheme.green.opacity(0.22), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
    } else if !account.isVerified {
      Text("Sign in")
        .font(AIMTheme.sans(10, weight: .medium))
        .foregroundStyle(AIMTheme.amber)
        .frame(
          width: MenuBarPopover.accountActionWidth,
          height: MenuBarPopover.accountActionHeight)
        .background(AIMTheme.amber.opacity(0.08))
        .overlay {
          RoundedRectangle(cornerRadius: AIMTheme.radius)
            .stroke(AIMTheme.amber.opacity(0.22), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
    } else {
      MenuBarSwitchButton(action: action)
    }
  }

  private var cardBackground: some ShapeStyle {
    if account.isActive {
      return AnyShapeStyle(LinearGradient(
        colors: [AIMTheme.panel2, AIMTheme.listSelection.opacity(0.55)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing))
    }
    if isSwitching { return AnyShapeStyle(AIMTheme.controlHover) }
    if isHovered && account.isVerified { return AnyShapeStyle(AIMTheme.listHover) }
    return AnyShapeStyle(LinearGradient(
      colors: [AIMTheme.panel2, AIMTheme.panel3.opacity(0.32)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing))
  }

  private var accessibilityLabel: String {
    var parts = [account.identity, error ?? account.detail]
    if let usage = account.usage {
      if let usedPercentage = usage.usedPercentage {
        parts.append("\(usedPercentage) percent used")
      }
      if let secondaryUsedPercentage = usage.secondaryUsedPercentage {
        parts.append("\(secondaryUsedPercentage) percent weekly used")
      }
    }
    return parts.joined(separator: ", ")
  }
}

private struct MenuBarQuotaRow: View {
  let label: String
  let percentage: Int
  let reset: String?
  let color: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(AIMTheme.sans(10, weight: .medium))
          .foregroundStyle(AIMTheme.muted)
        Text("\(percentage)%")
          .font(AIMTheme.mono(12, weight: .semibold))
          .foregroundStyle(AIMTheme.ink)
      }
      .frame(width: 52, alignment: .leading)
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(AIMTheme.control)
          Capsule()
            .fill(color)
            .frame(width: proxy.size.width * CGFloat(percentage) / 100)
        }
      }
      .frame(height: 5)
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: percentage)
      Text(reset ?? "")
        .font(AIMTheme.sans(9))
        .foregroundStyle(AIMTheme.muted)
        .lineLimit(1)
        .frame(width: 96, alignment: .trailing)
    }
    .frame(height: MenuBarPopover.quotaRowHeight)
  }
}

private struct MenuBarSwitchButton: View {
  let action: () -> Void
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      Text("Switch")
        .font(AIMTheme.sans(10, weight: .medium))
        .foregroundStyle(AIMTheme.ink)
        .frame(
          width: MenuBarPopover.accountActionWidth,
          height: MenuBarPopover.accountActionHeight)
        .background(isHovered ? AIMTheme.controlHover : AIMTheme.control.opacity(0.45))
        .overlay {
          RoundedRectangle(cornerRadius: AIMTheme.radius)
            .stroke(AIMTheme.lineSoft, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
        .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
    .onHover { isHovered = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover), value: isHovered)
    .accessibilityLabel("Use this account for new Codex sessions")
  }
}

private struct MenuBarHoverButton<Label: View>: View {
  let action: () -> Void
  @ViewBuilder let label: Label

  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) { label }
      .buttonStyle(AIMPressButtonStyle())
      .background(isHovered ? AIMTheme.listHover : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
      .onHover { hovered in
        withAnimation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover)) {
          isHovered = hovered
        }
      }
  }
}

#if AI_MANAGER_PREVIEW
@MainActor
enum MenuBarPopoverPreviewData {
  static let snapshot = MenuBarSnapshot(
    accounts: [
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "66D91DF8-056C-4DD0-AF97-EAF45D74A8D2")!,
        identity: "suraj@example.test", detail: "Codex CLI · Personal",
        isVerified: true, isActive: true,
        usage: MenuBarUsageSnapshot(
          usedPercentage: 42, secondaryUsedPercentage: 68,
          resetDescription: "Resets in 2h", secondaryResetDescription: "Monday",
          fetchedAt: Date().addingTimeInterval(-120))),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "15431467-BF10-4BCB-9300-C785336CB1D1")!,
        identity: "studio@example.test", detail: "Codex CLI · Studio",
        isVerified: true, isActive: false,
        usage: MenuBarUsageSnapshot(
          usedPercentage: 18, secondaryUsedPercentage: 37,
          resetDescription: "Resets tomorrow",
          secondaryResetDescription: "Monday", fetchedAt: Date().addingTimeInterval(-480))),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "DB9AB65A-F894-426D-8A16-86772A8F054D")!,
        identity: "needs-sign-in@example.test", detail: "Codex CLI · Personal",
        isVerified: false, isActive: false),
    ],
    primaryUsedPercentage: 42)
}
#endif
