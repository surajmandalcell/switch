import Foundation
import AIManagerCore
import SwitchAppModel

private struct BackupRunParams: Decodable { let setIDs: [String]? }

private struct BackupRestoreParams: Decodable {
    let setID: String
    let snapshotID: String
    let items: [String]?
    let destination: String?
    let includeLogins: Bool?
}

private struct BackupChangeParams: Decodable {
    let sourceID: String?
    let tool: String?
    let destination: String?
    let checked: Bool?
    let schedule: BackupSchedule?
    let keep: Int?
    let includeLogins: Bool?
    let promptsOnly: Bool?
}

/// Backup methods of architecture.md 2.9 (`backup.list` and `backup.history` are read methods). `backup.run` and
/// `backup.restore` have no 60 s limit; `$/cancelRequest` stops a run.
extension RPCServer {
    static let backupMethods = ["backup.checklist", "backup.run", "backup.restore", "backup.configure", "backup.retire",
                                "backup.setChecked", "backup.setShared"]

    /// Nil when `method` is not a backup method.
    func backupMethod(_ method: String, frame: Data) async throws -> (any Encodable)? {
        switch method {
        case "backup.checklist":
            return try await engine.backupChecklist()
        case "backup.run":
            let params = try? params(BackupRunParams.self, method: method, frame: frame)
            let ids = try params?.setIDs.map { try $0.map(setID) }
            let progress = progress(frame)
            return try await engine.runBackups(ids) { progress?($0) }
        case "backup.restore":
            let params = try params(BackupRestoreParams.self, method: method, frame: frame)
            return try await engine.restoreBackup(
                setID: try setID(params.setID), snapshotID: params.snapshotID, items: params.items ?? [],
                destination: params.destination.map { URL(fileURLWithPath: $0, isDirectory: true) },
                includeLogins: params.includeLogins ?? false) { [progress = progress(frame)] in progress?($0) }
        case "backup.configure", "backup.retire", "backup.setChecked", "backup.setShared":
            let params = try params(BackupChangeParams.self, method: method, frame: frame)
            func need<T>(_ value: T?, _ name: String) throws -> T {
                guard let value else { throw RPCError(-32602, "invalidParams", "\(method) needs \(name).") }
                return value
            }
            switch method {
            case "backup.configure":
                return try await engine.configureBackup(
                    sourceID: try need(params.sourceID, "sourceID"),
                    destination: URL(fileURLWithPath: try need(params.destination, "destination"), isDirectory: true),
                    schedule: params.schedule, keep: params.keep, includeLogins: params.includeLogins,
                    promptsOnly: params.promptsOnly)
            case "backup.retire":
                return try await engine.retireBackup(tool: try need(params.tool, "tool"))
            case "backup.setChecked":
                return try await engine.setBackupChecked(sourceID: try need(params.sourceID, "sourceID"),
                                                         checked: try need(params.checked, "checked"))
            default:
                return try await engine.setBackupShared(schedule: params.schedule, keep: params.keep,
                                                        includeLogins: params.includeLogins, promptsOnly: params.promptsOnly)
            }
        default:
            return nil
        }
    }

    private func setID(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw RPCError(-32602, "invalidParams", "setID must be a backup set UUID.") }
        return id
    }
}
