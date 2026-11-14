import Foundation
import AIManagerCore

// shortcut: written from AccountViewModel.setDroidMissionOwner, resumeDroidMission, startDroidMissionHere, and
// openDroidMission beside the Mac copies; delete those when the Mac app adopts SwitchAppModel (needs the window gates).
/// The Droid mission write paths of the Accounts page.
extension AppEngine {
    public func setMissionOwner(_ missionID: String, accountID: UUID) async throws -> ActionResult {
        try await perform(failure: "Couldn’t save the mission owner.", recovery: "Try again.") {
            try await self.requireManager().setDroidMissionOwner(folder: missionID, accountID: accountID)
            return .done()
        }
    }

    /// Opens `droid --resume <id>` in a terminal, in the mission's folder. A known owner that is not the Droid
    /// default asks first, then gets a guarded switch (a running Factory app asks again).
    public func resumeMission(_ missionID: String, confirmed: Set<ConfirmationRequest.Kind> = []) async throws
        -> ActionResult {
        let mission = try await self.mission(missionID)
        return try await perform(failure: "Couldn’t resume the mission.", recovery: "Check the mission folder, then try again.") {
            let manager = try self.requireManager()
            if let owner = mission.owner, owner != (await self.status?.defaultAccountIDs[ProviderID.droid.rawValue]),
               let account = await self.status?.accounts.first(where: { $0.id == owner }) {
                guard confirmed.contains(.missionSwitch) else {
                    return .confirm(ConfirmationRequest(
                        kind: .missionSwitch, title: "Switch Droid?",
                        message: "Switch Droid to \(self.label(account.identity)) and resume this mission?",
                        action: "Switch and Resume"))
                }
                do {
                    _ = try await manager.switchDefault(to: owner, allowRunningDroid: confirmed.contains(.droidRunning))
                } catch let error as DroidAccountError {
                    guard case .running = error, let request = ConfirmationRequest.droid(error, self.describe(error)) else {
                        throw error
                    }
                    return .confirm(request)
                }
                await self.reloadAccounts()
            }
            let notice = try await self.openMission(mission, arguments: ["--resume", mission.id], name: "Resume Droid mission")
            return .done(notice: notice)
        }
    }

    /// Starts a new mission on the default account from the plan of done and left features, after the user
    /// accepts that it uses that account's credit.
    public func startMissionHere(_ missionID: String, confirmed: Set<ConfirmationRequest.Kind> = []) async throws
        -> ActionResult {
        let mission = try await self.mission(missionID)
        return try await perform(failure: "Couldn’t start the mission.", recovery: "Check the mission folder, then try again.") {
            guard let id = await self.status?.defaultAccountIDs[ProviderID.droid.rawValue],
                  let account = await self.status?.accounts.first(where: { $0.id == id }) else {
                throw AIManagerError.accountNotFound
            }
            guard confirmed.contains(.missionStart) else {
                let name = self.label(account.identity)
                let features = mission.completed == 1 ? "feature" : "features"
                return .confirm(ConfirmationRequest(
                    kind: .missionStart, title: "Start a new mission?",
                    message: "Start a new mission on \(name) from this plan? It skips \(mission.completed) done "
                        + "\(features) and uses \(name)’s credit.", action: "Start"))
            }
            let plan = try await self.requireManager().writeDroidMissionPlan(folder: mission.id)
            let notice = try await self.openMission(mission, arguments: ["exec", "--mission", "-f", plan.path, "--auto", "high"],
                                                    name: "Start Droid mission")
            return .done(notice: notice)
        }
    }

    private func mission(_ id: String) async throws -> DroidMission {
        guard let mission = try await requireManager().droidMissions().first(where: { $0.id == id }) else {
            throw AppEngineError.notFound("No Droid mission has that id.")
        }
        return mission
    }

    private func openMission(_ mission: DroidMission, arguments: [String], name: String) async throws -> String {
        var isDirectory: ObjCBool = false
        guard let id = status?.defaultAccountIDs[ProviderID.droid.rawValue] else { throw AIManagerError.accountNotFound }
        guard FileManager.default.fileExists(atPath: mission.workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AIManagerError.operationFailed("The mission’s folder is gone: \(mission.workingDirectory)")
        }
        let spec = try await requireManager().launchSpec(
            accountID: id, arguments: arguments, workingDirectory: URL(fileURLWithPath: mission.workingDirectory, isDirectory: true))
        let notice = try await launch(spec, file: "mission-\(mission.id.prefix(8)).sh", what: "\(name) opens in a terminal",
                                      isolated: "Droid mission launch file", opened: "\(name) opened in Terminal.")
        setNotice(notice)
        return notice
    }
}
