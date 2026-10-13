#if AI_MANAGER_PREVIEW
import AIManagerCore
import Foundation

/// Preview data for Maintenance: a synthetic Mac in a temporary folder (tool homes with dated
/// conversations, logs, caches, old versions) and a synthetic backup drive. The real Cleanup scan
/// and Backup engine run on it, so every state on the page is real code on fake files.
struct MaintenanceDemo {
  let root: URL
  let paths: ManagerPaths
  var user: URL { root.appending(path: "user") }
  var drive: URL { root.appending(path: "Backup Drive") }

  static func make() -> MaintenanceDemo {
    removeStaleFolders()
    let root = FileManager.default.temporaryDirectory
      .appending(path: "switch-maintenance-preview-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: root)
    let user = root.appending(path: "user")
    let paths = ManagerPaths(
      applicationSupport: root.appending(path: "support"), defaultHome: user.appending(path: ".codex"),
      sharedRoot: user.appending(path: ".codex"), orcaAccountsRoot: root.appending(path: "orca"),
      grokHome: user.appending(path: ".grok"), droidHome: user.appending(path: ".factory"))
    let demo = MaintenanceDemo(root: root, paths: paths)
    try? FileManager.default.createDirectory(at: demo.drive, withIntermediateDirectories: true)
    demo.populate()
    return demo
  }

  /// Folders left by earlier previews that no longer run (a quit app removes its own).
  private static func removeStaleFolders() {
    let prefix = "switch-maintenance-preview-"
    let temporary = FileManager.default.temporaryDirectory
    for name in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix(prefix) {
      guard let pid = Int32(name.dropFirst(prefix.count)), kill(pid, 0) != 0, errno == ESRCH else { continue }
      try? FileManager.default.removeItem(at: temporary.appending(path: name))
    }
  }

  /// The preview's Claude Code account keeps its own profile folder, so the picker lists it.
  var profileHome: URL { root.appending(path: "accounts/claude-profile") }

  func sources(accounts: [AccountRecord]) -> [CleanupSource] {
    let mapped = accounts.map { account -> AccountRecord in
      var copy = account
      if copy.identity.providerID == .claudeCode { copy.home = profileHome }
      return copy
    }
    return CleanupSources.make(paths: paths, accounts: mapped)
  }

  private func write(_ path: String, in base: URL, kb: Int, daysAgo: Double, text: String? = nil) {
    let url = base.appending(path: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let body = text ?? "synthetic"
    FileManager.default.createFile(atPath: url.path, contents: Data(body.utf8))
    if kb > 0, let handle = try? FileHandle(forWritingTo: url) {
      try? handle.truncate(atOffset: UInt64(kb) * 1_024)
      try? handle.close()
    }
    let date = Date().addingTimeInterval(-daysAgo * 86_400)
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }

  /// A Codex transcript start: the session header, then what the person typed first.
  private func session(_ cwd: String, source: String = "\"cli\"", prompt: String) -> String {
    "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"\(cwd)\",\"source\":\(source)}}\n"
      + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(prompt)\"}}\n"
  }

  private func populate() {
    let codex = user.appending(path: ".codex")
    let projects: [(String, [(Double, Int, String)])] = [
      ("/Users/ada/dev/switch", [
        (2, 640, "Fix the popover separators"), (9, 5_200, "Rebuild the Maintenance page"),
        (33, 3_100, "Add a backup engine with hard links"), (47, 8_800, "Why does the quota ring flicker?"),
        (71, 1_900, "Port the account picker to SwiftUI")]),
      ("/Users/ada/dev/recap-pro", [
        (6, 2_400, "Draft the chapter recap script"), (41, 14_000, "Cast glossary needs spoiler rules"),
        (58, 4_300, "Export the season two report")]),
      ("/Users/ada/dev/website", [(95, 2_200, "Refresh the pricing page copy"), (120, 900, "Fix the mobile nav overflow")]),
    ]
    for (project, files) in projects {
      for (index, file) in files.enumerated() {
        write("sessions/2026/\(project.split(separator: "/").last!)-\(index).jsonl", in: codex, kb: file.1,
          daysAgo: file.0, text: session(project, prompt: file.2))
      }
    }
    for index in 0..<4 {
      write("sessions/2026/review-\(index).jsonl", in: codex, kb: 60, daysAgo: Double(8 + index * 12),
        text: session("/Users/ada/dev/switch", source: "{\"subagent\":{\"other\":\"guardian\"}}", prompt: "Review the pending diff"))
    }
    write("archived_sessions/old.jsonl", in: codex, kb: 3_300, daysAgo: 160,
      text: session("/Users/ada/dev/website", prompt: "Plan the first launch checklist"))
    for index in 0..<6 { write("log/codex-\(index).log", in: codex, kb: 800, daysAgo: Double(index * 9 + 1)) }
    write(".tmp/marketplaces/index", in: codex, kb: 38_000, daysAgo: 4)
    write("cache/remote_plugin_catalog/data", in: codex, kb: 12_000, daysAgo: 12)
    write("shell_snapshots/zsh-1.sh", in: codex, kb: 24, daysAgo: 30)
    write("history.jsonl", in: codex, kb: 620, daysAgo: 3)
    for (index, version) in ["0.157.1", "0.158.0", "0.159.2", "0.160.0", "0.160.1"].enumerated() {
      write("packages/standalone/releases/\(version)/codex", in: codex, kb: 60_000, daysAgo: Double(40 - index * 8))
    }
    try? FileManager.default.createSymbolicLink(
      at: codex.appending(path: "packages/standalone/current"),
      withDestinationURL: codex.appending(path: "packages/standalone/releases/0.160.1"))
    write("config.toml", in: codex, kb: 2, daysAgo: 1, text: "model = \"synthetic\"\n")
    write("AGENTS.md", in: codex, kb: 1, daysAgo: 20, text: "Synthetic instructions\n")
    write("auth.json", in: codex, kb: 1, daysAgo: 2, text: "{\"synthetic\":true}")

    let claude = user.appending(path: ".claude")
    for (project, folder, files) in [
      ("/Users/ada/dev/switch", "-Users-ada-dev-switch", [
        (1, 1_800, "Make the toolbar buttons match Sequoia"), (5, 900, "Why is the sidebar selection dim?"),
        (26, 6_400, "Speed up the page switch"), (52, 2_100, "Write tests for the restore flow")]),
      ("/Users/ada/dev/api", "-Users-ada-dev-api", [
        (14, 3_300, "Add pagination to the usage endpoint"), (80, 7_000, "Debug the token refresh race")]),
    ] {
      for (index, file) in files.enumerated() {
        let stem = "session-\(index)"
        write("projects/\(folder)/\(stem).jsonl", in: claude, kb: file.1, daysAgo: Double(file.0),
          text: "{\"cwd\":\"\(project)\"}\n{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(file.2)\"}}\n")
        write("projects/\(folder)/\(stem)/subagents/agent.jsonl", in: claude, kb: file.1 / 4, daysAgo: Double(file.0))
      }
    }
    for index in 0..<8 { write("debug/\(index).txt", in: claude, kb: 300, daysAgo: Double(index * 6)) }
    for index in 0..<5 { write("file-history/\(index)/v1", in: claude, kb: 700, daysAgo: Double(index * 11 + 2)) }
    write("cache/changelog.md", in: claude, kb: 90, daysAgo: 9)
    write("paste-cache/p.txt", in: claude, kb: 30, daysAgo: 15)
    for index in 0..<7 { write("backups/.claude.json.\(index)", in: claude, kb: 60, daysAgo: Double(index * 3 + 1)) }
    write("history.jsonl", in: claude, kb: 1_400, daysAgo: 1)
    write("settings.json", in: claude, kb: 1, daysAgo: 6, text: "{}")
    write("CLAUDE.md", in: claude, kb: 1, daysAgo: 6, text: "Synthetic notes\n")
    write(".credentials.json", in: claude, kb: 1, daysAgo: 6, text: "{\"synthetic\":true}")

    let grok = user.appending(path: ".grok")
    write("sessions/%2FUsers%2Fada%2Fdev%2Fswitch/one/updates.jsonl", in: grok, kb: 2_200, daysAgo: 17)
    write("sessions/%2FUsers%2Fada%2Fdev%2Fswitch/one/summary.json", in: grok, kb: 0, daysAgo: 17,
      text: "{\"generated_title\":\"Compare the sidebar spacing\"}")
    write("sessions/%2FUsers%2Fada%2Fdev%2Fswitch/two/updates.jsonl", in: grok, kb: 1_100, daysAgo: 64)
    write("sessions/%2FUsers%2Fada%2Fdev%2Fswitch/two/summary.json", in: grok, kb: 0, daysAgo: 64,
      text: "{\"generated_title\":\"Check the dark mode contrast\"}")
    write("logs/unified.jsonl", in: grok, kb: 4_400, daysAgo: 5)
    write("config.toml", in: grok, kb: 1, daysAgo: 9, text: "synthetic = true\n")

    for index in 0..<4 { write("debug/\(index).txt", in: profileHome, kb: 200, daysAgo: Double(index * 14 + 3)) }
    write("cache/changelog.md", in: profileHome, kb: 60, daysAgo: 21)
    for index in 0..<6 { write("backups/.claude.json.\(index)", in: profileHome, kb: 40, daysAgo: Double(index * 4 + 2)) }
    write(".credentials.json", in: profileHome, kb: 1, daysAgo: 4, text: "{\"synthetic\":true}")

    let gemini = user.appending(path: ".gemini")
    for index in 0..<3 { write("antigravity-cli/log/\(index).log", in: gemini, kb: 500, daysAgo: Double(index * 20 + 5)) }
    write("antigravity-cli/cache/index", in: gemini, kb: 8_000, daysAgo: 40)
    write("settings.json", in: gemini, kb: 1, daysAgo: 9, text: "{}")
    let copilot = user.appending(path: ".copilot")
    for index in 0..<3 { write("logs/\(index).log", in: copilot, kb: 300, daysAgo: Double(index * 25 + 8)) }
    settleDirectories()
  }

  /// Folders made just now would read as "in use". Each takes the date of its newest child.
  private func settleDirectories() {
    let manager = FileManager.default
    guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
    var folders: [URL] = []
    for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      folders.append(url)
    }
    for folder in folders.reversed() {
      let children = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      let newest = children.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
      if let newest { try? manager.setAttributes([.modificationDate: newest], ofItemAtPath: folder.path) }
    }
  }

  /// Saves one set per backed-up source and takes the snapshots the page shows. Runs once.
  static func seed(engine: BackupEngine, demo: MaintenanceDemo, sources: [CleanupSource]) async -> [BackupSet] {
    var sets: [BackupSet] = []
    for source in sources where ["codex", "claude"].contains(source.id) {
      guard let service = source.backupService else { continue }
      // The same items a new set starts with, so conversations are on, as they are for the owner.
      let items = source.backupItems
      sets.append(BackupSet(
        name: source.title, source: BackupSource(id: source.id, service: service, home: source.home), items: items,
        destination: demo.drive, schedule: source.id == "codex" ? .daily : .off, keep: 10))
    }
    guard (try? await engine.saveSets(sets)) != nil else { return [] }
    for set in sets {
      _ = try? await engine.snapshot(set)
      let changed = set.source.id == "codex" ? "config.toml" : "settings.json"
      try? Data("changed after the first backup\n".utf8).write(to: set.source.home.appending(path: changed))
      _ = try? await engine.snapshot(set)
      demo.spreadDates(of: set)
    }
    return sets
  }

  /// The engine stamps snapshots with the current time; the preview moves them back so the list reads like real use.
  private func spreadDates(of set: BackupSet) {
    let base = drive.appending(path: "Switch Backups/\(set.name)")
    let folders = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
      .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let hours: [Double] = set.source.id == "codex" ? [76, 5] : [30, 29]
    for (folder, back) in zip(folders, hours) {
      let url = folder.appending(path: BackupEngine.manifestName)
      guard let data = try? Data(contentsOf: url),
        var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      object["date"] = Date().addingTimeInterval(-back * 3_600).timeIntervalSinceReferenceDate
      if let updated = try? JSONSerialization.data(withJSONObject: object) { try? updated.write(to: url) }
    }
  }

  /// The preview model is synchronous, so wait for the seeding on a worker.
  static func seedSync(engine: BackupEngine, demo: MaintenanceDemo, sources: [CleanupSource]) -> ([BackupSet], [UUID: BackupStatus]) {
    let done = DispatchSemaphore(value: 0)
    let box = Box()
    Task.detached {
      box.sets = await seed(engine: engine, demo: demo, sources: sources)
      for set in box.sets { box.statuses[set.id] = try? await engine.status(for: set) }
      done.signal()
    }
    done.wait()
    return (box.sets, box.statuses)
  }

  private final class Box: @unchecked Sendable {
    var sets: [BackupSet] = []
    var statuses: [UUID: BackupStatus] = [:]
  }
}
#endif
