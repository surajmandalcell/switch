import AppKit
import SwiftUI

struct MenuBarUsageSnapshot: Equatable, Sendable {
  let usedPercentage: Int
  let plan: String?
  let resetDescription: String?

  init(usedPercentage: Int, plan: String? = nil, resetDescription: String? = nil) {
    self.usedPercentage = min(max(usedPercentage, 0), 100)
    self.plan = plan
    self.resetDescription = resetDescription
  }
}

struct MenuBarAccountSnapshot: Identifiable, Equatable, Sendable {
  let id: UUID
  let identity: String
  let detail: String
  let isVerified: Bool
  let isActive: Bool
  let usage: MenuBarUsageSnapshot?

  init(
    id: UUID,
    identity: String,
    detail: String,
    isVerified: Bool,
    isActive: Bool,
    usage: MenuBarUsageSnapshot? = nil
  ) {
    self.id = id
    self.identity = identity
    self.detail = detail
    self.isVerified = isVerified
    self.isActive = isActive
    self.usage = usage
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
  let addAccount: () -> Void
  let quit: () -> Void
  let switchAccount: (UUID) async throws -> Void
  let copyText: ((String) -> Void)?

  init(
    openMainWindow: @escaping () -> Void,
    addAccount: @escaping () -> Void,
    quit: @escaping () -> Void,
    switchAccount: @escaping (UUID) async throws -> Void,
    copyText: ((String) -> Void)? = nil
  ) {
    self.openMainWindow = openMainWindow
    self.addAccount = addAccount
    self.quit = quit
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

  func addAccount() {
    actions.addAccount()
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
    guard switchingAccountID == nil,
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
}

struct MenuBarPopover: View {
  static let width: CGFloat = 360
  static let minimumHeight: CGFloat = 192
  static let maximumHeight: CGFloat = 536
  static let headerHeight: CGFloat = 48
  static let footerHeight: CGFloat = 128
  static let accountRowHeight: CGFloat = 60
  static let maximumVisibleRows = 6

  @ObservedObject var store: MenuBarPopoverStore

  var body: some View {
    VStack(spacing: 0) {
      header
      accountList
      footer
    }
    .frame(width: Self.width)
    .background(AIMTheme.panel)
    .foregroundStyle(AIMTheme.ink)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }

  private var header: some View {
    MenuBarHoverButton(action: store.openMainWindow) {
      HStack(spacing: 10) {
        Image(systemName: "person.2")
          .font(.system(size: 15, weight: .medium))
          .frame(width: 18, height: 18)
          .accessibilityHidden(true)
        Text("Switch")
          .font(AIMTheme.sans(13, weight: .semibold))
        Spacer(minLength: 8)
        Text(accountCountLabel)
          .font(AIMTheme.sans(11, weight: .medium))
          .foregroundStyle(AIMTheme.muted)
        Image(systemName: "arrow.up.forward")
          .font(.system(size: 10, weight: .semibold))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 14)
      .frame(height: Self.headerHeight)
      .contentShape(Rectangle())
    }
    .accessibilityLabel("Open Switch")
    .overlay(alignment: .bottom) { Divider().overlay(AIMTheme.lineSoft) }
  }

  @ViewBuilder
  private var accountList: some View {
    if store.snapshot.accounts.isEmpty {
      VStack(spacing: 4) {
        Text("No accounts yet")
          .font(AIMTheme.sans(12, weight: .semibold))
        Text("Add a Codex account to get started.")
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
            error: store.rowErrors[account.id],
            copyError: { store.copyError($0) },
            action: { store.select(account) }
          )
        )
      }
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
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "info.circle")
          .font(.system(size: 11, weight: .regular))
          .accessibilityHidden(true)
        Text("Changes apply to new sessions. Running Codex sessions stay signed in.")
          .font(AIMTheme.sans(10))
          .foregroundStyle(AIMTheme.muted)
          .lineLimit(2)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .frame(height: 44)

      MenuBarHoverButton(action: store.addAccount) {
        HStack(spacing: 8) {
          Image(systemName: "plus")
            .font(.system(size: 11, weight: .semibold))
            .accessibilityHidden(true)
          Text("Add Account")
            .font(AIMTheme.sans(12, weight: .medium))
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .contentShape(Rectangle())
      }

      Divider().overlay(AIMTheme.lineSoft)

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
      .frame(height: 43)
    }
    .frame(height: Self.footerHeight)
    .background(AIMTheme.panel2)
    .overlay(alignment: .top) { Divider().overlay(AIMTheme.lineSoft) }
  }

  private var accountCountLabel: String {
    let count = store.snapshot.accounts.count
    return "\(count) account\(count == 1 ? "" : "s")"
  }
}

private struct MenuBarAccountRow: View {
  let account: MenuBarAccountSnapshot
  let isStriped: Bool
  let isSwitching: Bool
  let error: String?
  let copyError: (String) -> Void
  let action: () -> Void

  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      Button(action: action) {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text(account.identity)
              .font(AIMTheme.sans(12, weight: .medium))
              .lineLimit(1)
            Text(error ?? account.detail)
              .font(AIMTheme.sans(10))
              .foregroundStyle(error == nil ? AIMTheme.muted : AIMTheme.red)
              .lineLimit(1)
              .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          if let usage = account.usage {
            VStack(alignment: .trailing, spacing: 2) {
              Text("\(usage.usedPercentage)%")
                .font(AIMTheme.mono(12, weight: .semibold))
              if let detail = usageDetail(usage) {
                Text(detail)
                  .font(AIMTheme.sans(9))
                  .foregroundStyle(AIMTheme.muted)
                  .lineLimit(1)
              }
            }
          }

          if error == nil {
            statusAccessory
              .frame(width: 18, height: 18)
          }
        }
        .padding(.leading, 14)
        .padding(.trailing, error == nil ? 14 : 8)
        .frame(height: MenuBarPopover.accountRowHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(AIMPressButtonStyle())
      .disabled(!account.isVerified || isSwitching)

      if let error {
        Button { copyError(error) } label: {
          AIMIcon(name: .copy, size: 12)
            .foregroundStyle(AIMTheme.amber)
            .frame(width: 34, height: MenuBarPopover.accountRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(AIMPressButtonStyle())
        .help("Copy error")
        .accessibilityLabel("Copy account error")
      }
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

  private var rowBackground: some ShapeStyle {
    if account.isActive { return AnyShapeStyle(AIMTheme.listSelection) }
    if isSwitching { return AnyShapeStyle(AIMTheme.controlHover) }
    if isHovered && account.isVerified { return AnyShapeStyle(AIMTheme.listHover) }
    return AnyShapeStyle(isStriped ? AIMTheme.listStripe : AIMTheme.panel)
  }

  private func usageDetail(_ usage: MenuBarUsageSnapshot) -> String? {
    [usage.plan, usage.resetDescription].compactMap { value in
      guard let value, !value.isEmpty else { return nil }
      return value
    }.joined(separator: " · ").nilIfEmpty
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
          usedPercentage: 42, plan: "Plus", resetDescription: "Resets in 2h")),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "15431467-BF10-4BCB-9300-C785336CB1D1")!,
        identity: "studio@example.test", detail: "Studio · Verified",
        isVerified: true, isActive: false,
        usage: MenuBarUsageSnapshot(
          usedPercentage: 18, plan: "Team", resetDescription: "Resets tomorrow")),
      MenuBarAccountSnapshot(
        id: UUID(uuidString: "DB9AB65A-F894-426D-8A16-86772A8F054D")!,
        identity: "needs-sign-in@example.test", detail: "Sign-in required",
        isVerified: false, isActive: false),
    ],
    primaryUsedPercentage: 42)
}
#endif
