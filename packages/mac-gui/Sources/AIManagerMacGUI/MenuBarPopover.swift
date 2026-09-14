import AppKit
import SwiftUI

struct MenuBarUsageSnapshot: Equatable, Sendable {
  let usedPercentage: Int
  let secondaryUsedPercentage: Int?
  let plan: String?
  let resetDescription: String?
  let secondaryResetDescription: String?

  init(
    usedPercentage: Int,
    secondaryUsedPercentage: Int? = nil,
    plan: String? = nil,
    resetDescription: String? = nil,
    secondaryResetDescription: String? = nil
  ) {
    self.usedPercentage = min(max(usedPercentage, 0), 100)
    self.secondaryUsedPercentage = secondaryUsedPercentage.map { min(max($0, 0), 100) }
    self.plan = plan
    self.resetDescription = resetDescription
    self.secondaryResetDescription = secondaryResetDescription
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

  static let empty = MenuBarSnapshot(accounts: [], primaryUsedPercentage: nil)

  init(accounts: [MenuBarAccountSnapshot], primaryUsedPercentage: Int?) {
    self.accounts = accounts
    self.primaryUsedPercentage = primaryUsedPercentage.map { min(max($0, 0), 100) }
  }
}

@MainActor
struct MenuBarPopoverActions {
  let openMainWindow: () -> Void
  let quit: () -> Void
  let switchAccount: (UUID) async throws -> Void
  let refreshAccountUsage: (UUID) async -> Void
  let copyText: ((String) -> Void)?

  init(
    openMainWindow: @escaping () -> Void,
    quit: @escaping () -> Void,
    switchAccount: @escaping (UUID) async throws -> Void,
    refreshAccountUsage: @escaping (UUID) async -> Void = { _ in },
    copyText: ((String) -> Void)? = nil
  ) {
    self.openMainWindow = openMainWindow
    self.quit = quit
    self.switchAccount = switchAccount
    self.refreshAccountUsage = refreshAccountUsage
    self.copyText = copyText
  }
}

@MainActor
final class MenuBarPopoverStore: ObservableObject {
  @Published private(set) var snapshot: MenuBarSnapshot
  @Published private(set) var switchingAccountID: UUID?
  @Published private(set) var refreshingAccountID: UUID?
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

  func quit() {
    actions.quit()
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
    guard switchingAccountID == nil, refreshingAccountID == nil,
      account.isVerified,
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

  func refresh(_ account: MenuBarAccountSnapshot) {
    guard switchingAccountID == nil, refreshingAccountID == nil,
      account.isVerified, account.showsUsage else { return }
    refreshingAccountID = account.id
    Task { @MainActor [weak self] in
      guard let self else { return }
      await actions.refreshAccountUsage(account.id)
      refreshingAccountID = nil
    }
  }

}

struct MenuBarPopover: View {
  static let width: CGFloat = 384
  static let minimumHeight: CGFloat = 124
  static let maximumHeight: CGFloat = 424
  static let columnHeaderHeight: CGFloat = 24
  static let footerHeight: CGFloat = 40
  static let accountRowHeight: CGFloat = 60
  static let quotaWidth: CGFloat = 48
  static let statusWidth: CGFloat = 18
  static let trailingActionWidth: CGFloat = 34
  static let maximumVisibleRows = 6

  static func quotaText(_ percentage: Int?) -> String {
    percentage.map { "\($0)%" } ?? ""
  }

  @ObservedObject var store: MenuBarPopoverStore
  @AppStorage("keyboardFocusIndicators") private var showFocusIndicators = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      if !store.snapshot.accounts.isEmpty { columnHeader }
      accountList
      footer
    }
    .frame(width: Self.width)
    .background(AIMTheme.panel)
    .foregroundStyle(AIMTheme.ink)
    .environment(\.aimDarkMode, colorScheme == .dark)
    .environment(\.aimFocusIndicatorsEnabled, showFocusIndicators)
    .focusEffectDisabled(!showFocusIndicators)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }

  private var columnHeader: some View {
    HStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Account")
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(hasPrimaryUsage ? "5 hour" : "")
          .frame(width: Self.quotaWidth, alignment: .trailing)
        Text(hasSecondaryUsage ? "Weekly" : "")
          .frame(width: Self.quotaWidth, alignment: .trailing)
        Text("Use").frame(width: Self.statusWidth)
      }
      .padding(.leading, 14)
      .padding(.trailing, 8)
      Color.clear.frame(width: Self.trailingActionWidth)
    }
    .font(AIMTheme.sans(8, weight: .medium))
    .foregroundStyle(AIMTheme.muted)
    .textCase(.uppercase)
    .frame(height: Self.columnHeaderHeight)
    .background(AIMTheme.menuChrome)
    .overlay(alignment: .bottom) { Divider().overlay(AIMTheme.lineSoft) }
  }

  @ViewBuilder
  private var accountList: some View {
    if store.snapshot.accounts.isEmpty {
      VStack(spacing: 4) {
        Text("No accounts yet")
          .font(AIMTheme.sans(12, weight: .semibold))
        Text("Open Switch to add an account.")
          .font(AIMTheme.sans(11))
          .foregroundStyle(AIMTheme.muted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    } else {
      AIMVirtualList(
        items: store.snapshot.accounts,
        fixedRowHeight: Self.accountRowHeight,
        contentRevision: rowContentRevision
      ) { account in
        let index = store.snapshot.accounts.firstIndex(where: { $0.id == account.id }) ?? 0
        return AnyView(
          MenuBarAccountRow(
            account: account,
            isStriped: index.isMultiple(of: 2) == false,
            isSwitching: store.switchingAccountID == account.id,
            isRefreshing: store.refreshingAccountID == account.id,
            error: store.rowErrors[account.id],
            copyError: { store.copyError($0) },
            refresh: { store.refresh(account) },
            action: { store.select(account) }
          )
        )
      }
    }
  }

  private var rowContentRevision: Int {
    var hasher = Hasher()
    hasher.combine(store.switchingAccountID)
    hasher.combine(store.refreshingAccountID)
    for (id, error) in store.rowErrors.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      hasher.combine(id)
      hasher.combine(error)
    }
    return hasher.finalize()
  }

  private var footer: some View {
      HStack(spacing: 1) {
        MenuBarHoverButton(action: store.openMainWindow) {
          Text("Open Switch")
            .font(AIMTheme.sans(11, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        Divider().overlay(AIMTheme.lineSoft)
        MenuBarHoverButton(action: store.quit) {
          Text("Quit")
            .font(AIMTheme.sans(11, weight: .medium))
            .frame(width: 64)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
      }
    .frame(height: Self.footerHeight)
    .background(AIMTheme.menuChrome)
    .overlay(alignment: .top) { Divider().overlay(AIMTheme.lineSoft) }
  }

  private var hasPrimaryUsage: Bool {
    store.snapshot.accounts.contains { $0.usage != nil }
  }

  private var hasSecondaryUsage: Bool {
    store.snapshot.accounts.contains { $0.usage?.secondaryUsedPercentage != nil }
  }
}

private struct MenuBarAccountRow: View {
  let account: MenuBarAccountSnapshot
  let isStriped: Bool
  let isSwitching: Bool
  let isRefreshing: Bool
  let error: String?
  let copyError: (String) -> Void
  let refresh: () -> Void
  let action: () -> Void

  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      Button(action: action) {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 3) {
            Text(account.identity)
              .font(AIMTheme.sans(12, weight: .medium))
              .lineLimit(1)
            Text(error ?? rowDetail)
              .font(AIMTheme.sans(10))
              .foregroundStyle(error == nil ? AIMTheme.muted : AIMTheme.red)
              .lineLimit(1)
              .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          quota(account.usage?.usedPercentage)
          quota(account.usage?.secondaryUsedPercentage)

          if error == nil {
            statusAccessory
              .frame(width: MenuBarPopover.statusWidth, height: MenuBarPopover.statusWidth)
          } else {
            Color.clear.frame(width: MenuBarPopover.statusWidth, height: MenuBarPopover.statusWidth)
          }
        }
        .padding(.leading, 14)
        .padding(.trailing, error == nil ? 8 : 6)
        .frame(height: MenuBarPopover.accountRowHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(AIMPressButtonStyle())
      .disabled(!account.isVerified || isSwitching)

      trailingAction
        .frame(width: MenuBarPopover.trailingActionWidth, height: MenuBarPopover.accountRowHeight)
    }
    .background(rowBackground)
    .onHover { hovered in
      withAnimation(reduceMotion ? nil : .easeOut(duration: AIMMotion.hover)) {
        isHovered = hovered
      }
    }
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(account.isActive ? "Active account" : "Use for new Codex sessions")
  }

  @ViewBuilder private var trailingAction: some View {
    if let error {
        Button { copyError(error) } label: {
          AIMIcon(name: .copy, size: 12)
            .foregroundStyle(AIMTheme.amber)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(AIMPressButtonStyle())
        .help("Copy error")
        .accessibilityLabel("Copy account error")
    } else if account.usage == nil && account.isVerified && account.showsUsage {
        Button(action: refresh) {
          Group {
            if isRefreshing {
              ProgressView().controlSize(.small)
            } else {
              AIMIcon(name: .refresh, size: 11)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
        }
        .buttonStyle(AIMPressButtonStyle())
        .disabled(isRefreshing || isSwitching)
        .help("Refresh usage")
        .accessibilityLabel("Refresh usage for \(account.identity)")
    } else {
      Color.clear
    }
  }

  @ViewBuilder private var statusAccessory: some View {
    if isSwitching {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Switching account")
    } else if account.isActive {
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(AIMTheme.green)
        .accessibilityHidden(true)
    } else if !account.isVerified {
      Image(systemName: "exclamationmark.circle")
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(AIMTheme.amber)
        .accessibilityHidden(true)
    } else {
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(AIMTheme.faint)
        .accessibilityHidden(true)
    }
  }

  private func quota(_ percentage: Int?) -> some View {
    Text(MenuBarPopover.quotaText(percentage))
      .font(AIMTheme.mono(11, weight: percentage == nil ? .regular : .semibold))
      .foregroundStyle(percentage == nil ? AIMTheme.faint : AIMTheme.ink)
      .frame(width: MenuBarPopover.quotaWidth, alignment: .trailing)
  }

  private var rowBackground: some ShapeStyle {
    if account.isActive { return AnyShapeStyle(AIMTheme.listSelection) }
    if isSwitching { return AnyShapeStyle(AIMTheme.controlHover) }
    if isHovered && account.isVerified { return AnyShapeStyle(AIMTheme.listHover) }
    return AnyShapeStyle(isStriped ? AIMTheme.listStripe : AIMTheme.panel)
  }

  private func usageDetail(_ usage: MenuBarUsageSnapshot) -> String? {
    [usage.plan, usage.resetDescription, usage.secondaryResetDescription].compactMap { value in
      guard let value, !value.isEmpty else { return nil }
      return value
    }.joined(separator: " · ").nilIfEmpty
  }

  private var rowDetail: String {
    [account.detail, account.usage.flatMap(usageDetail)].compactMap { value in
      guard let value, !value.isEmpty else { return nil }
      return value
    }.joined(separator: " · ")
  }

  private var accessibilityLabel: String {
    var parts = [account.identity, error ?? account.detail]
    if let usage = account.usage {
      parts.append("\(usage.usedPercentage) percent used")
      if let detail = usageDetail(usage) { parts.append(detail) }
    }
    return parts.joined(separator: ", ")
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

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if AI_MANAGER_PREVIEW
@MainActor
enum MenuBarPopoverPreviewData {
  static let snapshot = MenuBarSnapshot(
    accounts: [
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "66D91DF8-056C-4DD0-AF97-EAF45D74A8D2")!,
        identity: "suraj@example.test", detail: "Personal · Verified",
        isVerified: true, isActive: true,
        usage: MenuBarUsageSnapshot(
          usedPercentage: 42, secondaryUsedPercentage: 68,
          plan: "Plus", resetDescription: "Resets in 2h", secondaryResetDescription: "Monday")),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "15431467-BF10-4BCB-9300-C785336CB1D1")!,
        identity: "studio@example.test", detail: "Studio · Verified",
        isVerified: true, isActive: false,
        usage: MenuBarUsageSnapshot(
          usedPercentage: 18, secondaryUsedPercentage: 37,
          plan: "Team", resetDescription: "Resets tomorrow")),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "DB9AB65A-F894-426D-8A16-86772A8F054D")!,
        identity: "needs-sign-in@example.test", detail: "Sign-in required",
        isVerified: false, isActive: false),
    ],
    primaryUsedPercentage: 42)
}
#endif
