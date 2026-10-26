import AIManagerCore
import SwiftUI

/// Droid missions on this Mac, newest first, in the Droid section of Accounts. The model hides the
/// card when there are none. Switch only reads the mission folders; Resume and Start here run Droid
/// in Terminal.
struct DroidMissionsCard: View {
  @ObservedObject var model: AccountViewModel
  // Owner names follow these choices, so the card redraws when one changes.
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @AppStorage(EmailPrivacy.privacyModeKey) private var privacyMode = false
  @AppStorage(EmailPrivacy.domainsKey) private var showEmailDomains = false

  var body: some View {
    let missions = model.droidMissions
    let accounts = model.status?.accounts.filter { $0.identity.providerID == .droid } ?? []
    let defaultID = model.status?.defaultAccountID(for: .droid)
    AIMCard(title: "Missions", divider: true, bottomInset: 0, accessory: {
      Text("\(missions.count)").aimText(.secondary).monospacedDigit()
    }) {
      VStack(spacing: 0) {
        ForEach(Array(missions.enumerated()), id: \.element.id) { index, mission in
          DroidMissionRow(
            mission: mission, model: model, accounts: accounts, defaultID: defaultID,
            ownerName: accounts.first { $0.id == mission.owner }?.identity.accountLabel
          )
          .overlay(alignment: .top) { if index > 0 { AIMRowSeparator().allowsHitTesting(false) } }
          // The two-line text ends 3 pt above its row's bottom, so the last row takes 11 pt more to
          // end 14 pt above the card's edge, as the title starts 14 pt below the top.
          .padding(.bottom, index == missions.count - 1 ? AIMTheme.contentInset - 3 : 0)
        }
      }
    }
  }
}

private struct DroidMissionRow: View {
  let mission: DroidMission
  @ObservedObject var model: AccountViewModel
  let accounts: [AccountRecord]
  let defaultID: UUID?
  let ownerName: String?

  /// "131 of 160 done · 26 cancelled · Work · Oct 17"
  static func detail(_ mission: DroidMission, owner: String?) -> String {
    var parts = [mission.total == 0 ? "No features yet"
      : mission.left == 0 ? "Done" : "\(mission.completed) of \(mission.total) done"]
    if mission.cancelled > 0 { parts.append("\(mission.cancelled) cancelled") }
    parts.append(owner ?? "Owner unknown")
    if mission.createdAt > .distantPast { parts.append(mission.createdAt.formatted(.dateTime.month(.abbreviated).day())) }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    let detail = Self.detail(mission, owner: ownerName)
    // Another account's mission, or one with no known owner, can start again on the default.
    let startsHere = mission.left > 0 && (mission.owner == nil || mission.owner != defaultID)
    AIMTableRow {
      VStack(alignment: .leading, spacing: 0) {
        Text(mission.title).aimText(.body).lineLimit(1).truncationMode(.tail)
          .help(mission.title)
        Text(detail).aimText(.secondary).lineLimit(1).truncationMode(.tail)
          .help(detail)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(mission.title)
      .accessibilityValue("\(detail). \(mission.state)")
      .help("\(mission.title)\n\(detail)" + (mission.state.isEmpty ? "" : "\nState: \(mission.state)"))
      HStack(spacing: AIMTheme.rowSpacing) {
        Button("Resume") { Task { await model.resumeDroidMission(mission) } }
          .buttonStyle(AIMPushButtonStyle())  // "Resume" is wider than rowButtonWidth and would truncate
          .disabled(model.isBusy)
        if startsHere {
          Button("Start here") { Task { await model.startDroidMissionHere(mission) } }
            .buttonStyle(AIMPushButtonStyle())
            .disabled(model.isBusy)
        }
        AIMIconMenu(icon: .ellipsis, label: "More actions") {
          Menu("Set owner") {
            ForEach(accounts) { account in
              Button(account.identity.accountLabel) {
                Task { await model.setDroidMissionOwner(mission, to: account.id) }
              }
            }
          }
        }
        .help("More actions for this mission")
      }
      .uiLint(.actions)
    }
  }
}
