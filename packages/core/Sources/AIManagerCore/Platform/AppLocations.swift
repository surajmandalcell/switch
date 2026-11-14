import Foundation

/// Data-location rules of architecture.md section 5 (plan unit P11, the migration part).
public enum AppLocations {
    /// The Linux data folder before the rename to `switch`.
    static let oldLinuxName = "AI Manager"

    /// Linux, real home only: the one-time move of `~/.local/share/AI Manager` to `~/.local/share/switch`. Returns
    /// the notice to show when both folders exist (the new one is used; nothing is merged). Elsewhere nil.
    public static func migrateDataRoot(_ paths: ManagerPaths) throws -> String? {
        #if os(Linux)
        guard paths.isolationRoot == nil, paths.applicationSupport.lastPathComponent == "switch" else { return nil }
        let old = paths.applicationSupport.deletingLastPathComponent().appending(path: oldLinuxName)
        return try migrateDataRoot(from: old, to: paths.applicationSupport)
        #else
        return nil
        #endif
    }

    /// Renames `old` to `new` under `old`'s `manager.lock`, after writing `migrated-from` (the old path) into it,
    /// so a crash leaves either the old folder (moved on the next start) or the new one with its marker.
    static func migrateDataRoot(from old: URL, to new: URL) throws -> String? {
        guard CoreSupport.entryExists(old) else { return nil }
        guard !CoreSupport.entryExists(new) else {
            return "Switch uses its data folder \(new.path). The older folder \(old.path) was left as it is; "
                + "remove it once you no longer need it."
        }
        guard let lock = try FileLock(at: old.appending(path: "manager.lock")) else {
            throw AIManagerError.operationFailed(
                "Another Switch process is using \(old.path). Quit it, then start Switch again to move its data.")
        }
        try Data(old.path.utf8).write(to: old.appending(path: "migrated-from"), options: .atomic)
        try FileManager.default.moveItem(at: old, to: new)
        withExtendedLifetime(lock) {}
        return nil
    }
}
