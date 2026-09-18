import AppKit
import AIManagerCore
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

  init?(bucket: CodexRateLimitBucketSnapshot, fetchedAt: Date) {
    let primaryIsWeekly = bucket.primary?.windowDurationMinutes == 10_080
    let session = primaryIsWeekly ? bucket.secondary : bucket.primary
    let weekly = primaryIsWeekly ? bucket.primary : bucket.secondary
    guard session?.usedPercent != nil || weekly?.usedPercent != nil else { return nil }
    self.init(
      usedPercentage: session?.usedPercent,
      secondaryUsedPercentage: weekly?.usedPercent,
      resetDescription: session?.resetsAt.map { "resets \($0.formatted(.relative(presentation: .named)))" },
      secondaryResetDescription: weekly?.resetsAt.map { "resets \($0.formatted(.relative(presentation: .named)))" },
      fetchedAt: fetchedAt)
  }

}

struct MenuBarAccountSnapshot: Identifiable, Equatable, Sendable {
  let id: UUID
  let providerID: ProviderID
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
    showsUsage: Bool = true,
    providerID: ProviderID = .codex
  ) {
    self.id = id
    self.providerID = providerID
    self.identity = identity
    self.detail = detail
    self.isVerified = isVerified
    self.isActive = isActive
    self.usage = showsUsage ? usage : nil
    self.showsUsage = showsUsage
  }

  var remainingPercentage: Int? {
    (usage?.usedPercentage ?? usage?.secondaryUsedPercentage).map { 100 - $0 }
  }
}

struct MenuBarSnapshot: Equatable, Sendable {
  let accounts: [MenuBarAccountSnapshot]
  let lastRefreshedAt: Date?

  var statusAccounts: [MenuBarAccountSnapshot] {
    statusAccountGroups.flatMap { $0 }
  }

  var statusAccountGroups: [[MenuBarAccountSnapshot]] {
    var groups: [[MenuBarAccountSnapshot]] = []
    for account in accounts.filter(\.showsUsage).prefix(4) {
      if let index = groups.firstIndex(where: { $0.first?.providerID == account.providerID }) {
        groups[index].append(account)
      } else {
        groups.append([account])
      }
    }
    return groups
  }

  static let empty = MenuBarSnapshot(
    accounts: [], lastRefreshedAt: nil)

  init(
    accounts: [MenuBarAccountSnapshot],
    lastRefreshedAt: Date? = nil
  ) {
    self.accounts = accounts
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

struct MenuBarPalette {
  let surface, card, ink, muted, track, accent, active, line: Color
  static let ivory = MenuBarPalette(dark: false)
  static let espresso = MenuBarPalette(dark: true)

  private init(dark: Bool) {
    surface = Color(hex: dark ? 0x292722 : 0xF0ECE2)
    card = Color(hex: dark ? 0x3B372F : 0xFFFDF6)
    ink = Color(hex: dark ? 0xF1E8D5 : 0x323229)
    muted = Color(hex: dark ? 0xC8BCA6 : 0x6B665A)
    track = Color(hex: dark ? 0x625B4B : 0xE0DED4)
    accent = Color(hex: dark ? 0xB4C8DD : 0x4B706E)
    active = Color(hex: dark ? 0x504A3E : 0xE9E7DF)
    line = Color(hex: dark ? 0x534A3B : 0xDCD8CC)
  }
}

struct MenuBarPopover: View {
  static let width: CGFloat = 344
  static let minimumHeight: CGFloat = 104
  static let footerHeight: CGFloat = 29
  static let listInset: CGFloat = 10
  static let cardSpacing: CGFloat = 10
  static let accountHeaderHeight: CGFloat = 35
  static let quotaRowHeight: CGFloat = 40
  static let quotaSpacing: CGFloat = 13
  static let accountActionWidth: CGFloat = 56
  static let accountActionHeight: CGFloat = 22
  static let popupRadius: CGFloat = 9
  static let cardRadius: CGFloat = 7
  static let buttonRadius: CGFloat = 3

  static func accountRowHeight(_ account: MenuBarAccountSnapshot) -> CGFloat {
    let quotaCount = [account.usage?.secondaryUsedPercentage, account.usage?.usedPercentage]
      .compactMap { $0 }.count
    guard account.showsUsage, quotaCount > 0 else { return accountHeaderHeight }
    return accountHeaderHeight + 14 + CGFloat(quotaCount) * quotaRowHeight
      + CGFloat(max(0, quotaCount - 1)) * quotaSpacing
  }

  @ObservedObject var store: MenuBarPopoverStore
  @AppStorage("keyboardFocusIndicators") private var showFocusIndicators = false
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  private var palette: MenuBarPalette { colorScheme == .dark ? .espresso : .ivory }

  var body: some View {
    VStack(spacing: 0) {
      accountList
      footer
    }
    .frame(width: Self.width, height: AIManagerStatusItemController.contentSize(
      accounts: store.snapshot.accounts,
      visibleScreenHeight: AIManagerStatusItemController.smallestDisplayHeight).height)
    .background {
      if reduceTransparency {
        palette.surface
      } else {
        AIMVisualEffect(
          material: .popover, blendingMode: .behindWindow, darkMode: colorScheme == .dark)
          .overlay(palette.surface.opacity(0.92))
          .allowsHitTesting(false)
      }
    }
    .foregroundStyle(palette.ink)
    .environment(\.aimDarkMode, colorScheme == .dark)
    .environment(\.aimFocusIndicatorsEnabled, showFocusIndicators)
    .focusEffectDisabled(!showFocusIndicators)
    .clipShape(RoundedRectangle(cornerRadius: Self.popupRadius))
  }

  @ViewBuilder
  private var accountList: some View {
    if store.snapshot.accounts.isEmpty {
      VStack(spacing: 4) {
        Text("No accounts yet")
          .font(AIMTheme.sans(14, weight: .semibold))
        Text("Open the app to add an account.")
          .font(AIMTheme.sans(11))
          .foregroundStyle(palette.muted)
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
            palette: palette,
            translucent: !reduceTransparency,
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
    hasher.combine(reduceTransparency)
    for (id, error) in store.rowErrors.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      hasher.combine(id)
      hasher.combine(error)
    }
    return hasher.finalize()
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if let refreshedAt = store.snapshot.lastRefreshedAt {
        Text("Refreshed \(refreshedAt.formatted(.relative(presentation: .numeric)))")
          .font(AIMTheme.sans(9))
          .foregroundStyle(palette.muted)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      MenuBarActionButton(title: "Open App", palette: palette, action: store.openMainWindow)
    }
    .padding(.horizontal, 10)
    .frame(height: Self.footerHeight)
    .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
  }
}

private struct MenuBarAccountRow: View {
  let account: MenuBarAccountSnapshot
  let palette: MenuBarPalette
  let translucent: Bool
  let isSwitching: Bool
  let error: String?
  let copyError: (String) -> Void
  let action: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Group {
          if let image = AIManagerBrand.providerGlyph(for: account.providerID) {
            Image(nsImage: image).resizable().scaledToFit()
          } else {
            AIMIcon(name: .terminal, size: 12)
          }
        }
        .frame(width: 12, height: 12)
        .foregroundStyle(palette.muted)
        .accessibilityHidden(true)
        Text(account.identity)
          .font(AIMTheme.sans(11, weight: .semibold))
          .lineLimit(1).truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(account.identity)
        if let error {
          Button { copyError(error) } label: {
            AIMIcon(name: .copy, size: 12)
              .foregroundStyle(AIMTheme.amber)
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(AIMPressButtonStyle())
          .background { AIMCopyCursor(enabled: true).allowsHitTesting(false) }
          .help("\(error) Click to copy.")
          .accessibilityLabel("Copy account error")
        }
        switchControl
      }
      .padding(.horizontal, 11)
      .frame(height: MenuBarPopover.accountHeaderHeight)

      if let usage = account.usage, account.showsUsage,
         usage.usedPercentage != nil || usage.secondaryUsedPercentage != nil
      {
        VStack(spacing: MenuBarPopover.quotaSpacing) {
          if let percentage = usage.usedPercentage {
            MenuBarQuotaRow(
              label: "Session", percentage: percentage,
              reset: usage.resetDescription, palette: palette)
          }
          if let percentage = usage.secondaryUsedPercentage {
            MenuBarQuotaRow(
              label: "Weekly", percentage: percentage,
              reset: usage.secondaryResetDescription, palette: palette)
          }
        }
        .padding(.horizontal, 11)
        .padding(.top, 4)
        .padding(.bottom, 10)
      }
    }
    .frame(height: MenuBarPopover.accountRowHeight(account))
    .foregroundStyle(palette.ink)
    .background(palette.card.opacity(translucent ? 0.94 : 1))
    .clipShape(RoundedRectangle(cornerRadius: MenuBarPopover.cardRadius))
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
        .background(palette.active)
        .clipShape(RoundedRectangle(cornerRadius: MenuBarPopover.buttonRadius))
        .accessibilityLabel("Switching account")
    } else if account.isActive {
      MenuBarActionButton(title: "Active", disabled: true, palette: palette, action: {})
    } else if !account.isVerified {
      Text("Sign in")
        .font(AIMTheme.sans(10, weight: .medium))
        .foregroundStyle(AIMTheme.amber)
        .frame(
          width: MenuBarPopover.accountActionWidth,
          height: MenuBarPopover.accountActionHeight)
        .background(AIMTheme.amber.opacity(0.08))
        .overlay {
          RoundedRectangle(cornerRadius: MenuBarPopover.buttonRadius)
            .stroke(AIMTheme.amber.opacity(0.22), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MenuBarPopover.buttonRadius))
    } else {
      MenuBarActionButton(palette: palette, action: action)
    }
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
  let palette: MenuBarPalette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(AIMTheme.sans(11, weight: .medium))
        .foregroundStyle(palette.ink)
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(palette.track)
          Capsule()
            .fill(palette.accent)
            .frame(width: proxy.size.width * CGFloat(percentage) / 100)
        }
      }
      .frame(height: 4)
      .animation(reduceMotion ? nil : .easeOut(duration: AIMMotion.state), value: percentage)
      HStack(spacing: 8) {
        Text("\(percentage)% used")
          .font(AIMTheme.sans(10, weight: .medium))
          .foregroundStyle(palette.ink)
        Spacer(minLength: 0)
        Text(reset ?? "")
          .font(AIMTheme.sans(9))
          .foregroundStyle(palette.muted)
          .lineLimit(1)
      }
    }
    .frame(height: MenuBarPopover.quotaRowHeight)
  }
}

private struct MenuBarActionButton: View {
  var title = "Switch"
  var disabled = false
  let palette: MenuBarPalette
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(AIMTheme.sans(10, weight: .medium))
        .foregroundStyle(disabled ? palette.muted : title == "Switch" ? palette.accent : palette.ink)
        .frame(
          width: MenuBarPopover.accountActionWidth,
          height: MenuBarPopover.accountActionHeight)
        .background {
          AIMHoverBackground(base: disabled ? palette.active : .clear,
            highlight: (title == "Switch" ? palette.accent : palette.ink).opacity(0.08),
            hovered: isHovered && !disabled)
        }
        .overlay {
          if title == "Switch", !disabled {
            RoundedRectangle(cornerRadius: MenuBarPopover.buttonRadius)
              .stroke(palette.accent, lineWidth: 1)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: MenuBarPopover.buttonRadius))
        .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
    .disabled(disabled)
    .onHover { isHovered = $0 && !disabled }
    .accessibilityLabel(disabled ? "Active account"
      : title == "Switch" ? "Use this account for new Codex sessions" : title)
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
    ])
}
#endif
