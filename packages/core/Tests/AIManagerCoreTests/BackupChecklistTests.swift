import Foundation
import XCTest
@testable import AIManagerCore

/// The Backup checklist: several tools into one folder, Claude Code with its profile folders, migration, unchecking.
final class BackupChecklistTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var drive: URL!
    private var engine: BackupEngine!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "switch-checklist-\(UUID().uuidString)").resolvingSymlinksInPath()
        drive = root.appending(path: "drive")
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        engine = BackupEngine(applicationSupport: root.appending(path: "support"))
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func write(_ path: String, _ text: String, in home: URL) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func home(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func inode(_ url: URL) -> UInt64 {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return UInt64(info.st_ino)
    }

    private func codexSet(_ codex: URL, destination: URL? = nil) -> BackupSet {
        BackupSet(name: "Codex CLI", source: BackupSource(id: "codex", service: .codex, home: codex),
                  items: [BackupItem("sessions"), BackupItem("config.toml")], destination: destination ?? drive)
    }

    /// Claude Code: the shared ~/.claude plus one account profile folder.
    private func claudeSet(_ claude: URL, profile: URL, destination: URL? = nil) -> BackupSet {
        let set = BackupSet(name: "Claude Code", source: BackupSource(id: "claude", service: .claude, home: claude),
                            items: [BackupItem("projects"), BackupItem("settings.json")], destination: destination ?? drive)
        return BackupChecklist.withProfiles(set, homes: [profile])
    }

    func testTwoToolsShareOneFolderEachInItsOwnSubfolder() async throws {
        let codex = try home("codex"), claude = try home("claude"), profile = try home("accounts/profile-a")
        try write("sessions/a.jsonl", "one", in: codex)
        try write("projects/p/s.jsonl", "two", in: claude)
        let first = try await engine.snapshot(codexSet(codex))
        let second = try await engine.snapshot(claudeSet(claude, profile: profile))
        XCTAssertEqual(first.folder.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Switch Backups")
        XCTAssertEqual(first.folder.deletingLastPathComponent().lastPathComponent, "Codex CLI")
        XCTAssertEqual(second.folder.deletingLastPathComponent().lastPathComponent, "Claude Code")
        XCTAssertEqual(first.folder.deletingLastPathComponent().deletingLastPathComponent(),
                       second.folder.deletingLastPathComponent().deletingLastPathComponent())
    }

    func testSecondRunLinksUnchangedFilesAndCopiesOnlyWhatChanged() async throws {
        let codex = try home("codex")
        try write("sessions/same.jsonl", String(repeating: "x", count: 3_000), in: codex)
        try write("sessions/edit.jsonl", "old", in: codex)
        let set = codexSet(codex)
        let full = try await engine.snapshot(set)
        XCTAssertEqual(full.newBytes, full.totalBytes, "the first backup copies everything")
        try write("sessions/edit.jsonl", "newer text", in: codex)
        let next = try await engine.snapshot(set)
        XCTAssertEqual(next.files, 2, "each snapshot stays complete")
        XCTAssertEqual(next.newBytes, Int64("newer text".count))
        XCTAssertEqual(inode(full.folder.appending(path: "files/sessions/same.jsonl")),
                       inode(next.folder.appending(path: "files/sessions/same.jsonl")))
        XCTAssertNotEqual(inode(full.folder.appending(path: "files/sessions/edit.jsonl")),
                          inode(next.folder.appending(path: "files/sessions/edit.jsonl")))
    }

    func testClaudeCodeSetIncludesProfileFolderAndRestoresIt() async throws {
        let claude = try home("claude"), profile = try home("accounts/profile-a")
        try write("projects/p/s.jsonl", "shared chat", in: claude)
        try write("backups/b.json", "profile backup", in: profile)
        try write(".credentials.json", "secret", in: profile)
        var set = claudeSet(claude, profile: profile)
        XCTAssertTrue(set.items.contains { $0.path == "_profiles/profile-a/backups" })
        XCTAssertTrue(set.items.contains { $0.path == "_profiles/profile-a/.credentials.json" && $0.isLogin })
        let snapshot = try await engine.snapshot(set)
        let paths = Set(snapshot.manifest.entries.map(\.path))
        XCTAssertTrue(paths.contains("projects/p/s.jsonl"))
        XCTAssertTrue(paths.contains("_profiles/profile-a/backups/b.json"))
        XCTAssertFalse(paths.contains("_profiles/profile-a/.credentials.json"), "login files stay out by default")
        // The second run links the profile's unchanged file too.
        let again = try await engine.snapshot(set)
        XCTAssertEqual(again.newBytes, 0)
        XCTAssertEqual(inode(snapshot.folder.appending(path: "files/_profiles/profile-a/backups/b.json")),
                       inode(again.folder.appending(path: "files/_profiles/profile-a/backups/b.json")))
        // In place, the profile file returns to the profile folder, after a safety copy of what it replaces.
        try write("backups/b.json", "damaged", in: profile)
        let restored = try await engine.restore(snapshot, set: set)
        XCTAssertEqual(try String(contentsOf: profile.appending(path: "backups/b.json"), encoding: .utf8), "profile backup")
        XCTAssertNotNil(restored.safetySnapshot)
        XCTAssertTrue(restored.safetySnapshot!.manifest.entries.contains { $0.path == "_profiles/profile-a/backups/b.json" })
        // Into a folder, it keeps its stored path and the real profile is not touched.
        let out = root.appending(path: "restored")
        try write("backups/b.json", "changed again", in: profile)
        _ = try await engine.restore(snapshot, set: set, to: out)
        XCTAssertEqual(try String(contentsOf: out.appending(path: "_profiles/profile-a/backups/b.json"), encoding: .utf8), "profile backup")
        XCTAssertEqual(try String(contentsOf: profile.appending(path: "backups/b.json"), encoding: .utf8), "changed again")
        set.includeLogins = true
        let withLogins = try await engine.snapshot(set)
        XCTAssertTrue(withLogins.manifest.entries.contains { $0.path == "_profiles/profile-a/.credentials.json" })
    }

    func testOldSavedSetsStillDecode() throws {
        let old = """
        {"id":"\(UUID().uuidString)","name":"Codex CLI","source":{"id":"codex","service":"codex","home":"file:///tmp/h/"},
         "items":[{"path":"sessions","isLogin":false}],"destination":"file:///tmp/d/","includeLogins":false,"schedule":"daily","keep":5}
        """
        let set = try JSONDecoder().decode(BackupSet.self, from: Data(old.utf8))
        XCTAssertFalse(set.retired)
        XCTAssertTrue(set.profiles.isEmpty)
        XCTAssertEqual(set.toolKey, "codex")
    }

    func testMigrationFoldsOwnProfileSetIntoClaudeCodeAndKeepsItsSnapshots() async throws {
        let claude = try home("claude"), profile = try home("accounts/profile-a")
        try write("projects/p/s.jsonl", "shared", in: claude)
        try write("backups/b.json", "own", in: profile)
        let shared = BackupSet(name: "Claude Code", source: BackupSource(id: "claude", service: .claude, home: claude),
                               items: [BackupItem("projects")], destination: drive, schedule: .daily)
        let own = BackupSet(name: "Claude Code abcd1234", source: BackupSource(id: "claude:abcd1234", service: .claude, home: profile),
                            items: [BackupItem("backups")], destination: drive, schedule: .weekly)
        let ownSnapshot = try await engine.snapshot(own)
        let migrated = BackupChecklist.migrate([shared, own], lastUsed: [own.id: Date()])
        let claudeSet = try XCTUnwrap(migrated.sets.first { $0.id == shared.id })
        XCTAssertFalse(claudeSet.retired)
        XCTAssertEqual(claudeSet.profiles["profile-a"], profile)
        XCTAssertTrue(claudeSet.items.contains { $0.path == "_profiles/profile-a/backups" })
        let folded = try XCTUnwrap(migrated.sets.first { $0.id == own.id })
        XCTAssertTrue(folded.retired)
        XCTAssertEqual(folded.schedule, .off)
        // The old snapshots are still listed and restorable through the retired set.
        let status = try await engine.status(for: folded)
        XCTAssertEqual(status.snapshots.map(\.id), [ownSnapshot.id])
        let out = root.appending(path: "out")
        _ = try await engine.restore(status.snapshots[0], set: folded, to: out)
        XCTAssertEqual(try String(contentsOf: out.appending(path: "backups/b.json"), encoding: .utf8), "own")
        // Running it again changes nothing.
        let again = BackupChecklist.migrate(migrated.sets, lastUsed: [:])
        XCTAssertEqual(again.sets, migrated.sets)
    }

    func testMigrationUsesTheMostRecentFolderAndKeepsOlderSnapshotsInHistory() async throws {
        let codex = try home("codex"), claude = try home("claude")
        try write("sessions/a.jsonl", "a", in: codex)
        try write("projects/p/s.jsonl", "b", in: claude)
        let other = root.appending(path: "other-drive")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let oldCodex = codexSet(codex, destination: other)
        let newClaude = BackupSet(name: "Claude Code", source: BackupSource(id: "claude", service: .claude, home: claude),
                                  items: [BackupItem("projects")], destination: drive, schedule: .weekly, keep: 5)
        let kept = try await engine.snapshot(oldCodex)
        let migrated = BackupChecklist.migrate([oldCodex, newClaude], lastUsed: [oldCodex.id: Date(timeIntervalSinceNow: -100), newClaude.id: Date()])
        XCTAssertEqual(migrated.folder, drive)
        let active = migrated.sets.filter { !$0.retired }
        XCTAssertEqual(Set(active.map(\.toolKey)), ["codex", "claude"])
        XCTAssertTrue(active.allSatisfy { BackupChecklist.sameFolder($0.destination, drive) })
        let old = try XCTUnwrap(migrated.sets.first { $0.id == oldCodex.id })
        XCTAssertTrue(old.retired)
        XCTAssertTrue(BackupChecklist.sameFolder(old.destination, other))
        let status = try await engine.status(for: old)
        XCTAssertEqual(status.snapshots.map(\.id), [kept.id], "the old folder keeps its history")
        let next = try XCTUnwrap(active.first { $0.toolKey == "codex" })
        XCTAssertEqual(next.name, "Codex CLI")
        XCTAssertNotEqual(next.id, old.id)
    }

    func testUncheckingStopsTheScheduleAndKeepsSnapshotsAndSourceFiles() async throws {
        let codex = try home("codex")
        try write("sessions/a.jsonl", "keep me", in: codex)
        var set = codexSet(codex)
        set.schedule = .daily
        let snapshot = try await engine.snapshot(set)
        let sets = BackupChecklist.retire([set], tool: "codex")
        XCTAssertTrue(sets[0].retired)
        XCTAssertEqual(sets[0].schedule, .off)
        let status = try await engine.status(for: sets[0])
        XCTAssertEqual(status.snapshots.map(\.id), [snapshot.id])
        XCTAssertTrue(fm.fileExists(atPath: snapshot.folder.appending(path: "files/sessions/a.jsonl").path))
        XCTAssertTrue(fm.fileExists(atPath: codex.appending(path: "sessions/a.jsonl").path))
        // Moving the shared folder retires a retired set's neighbors only; a retired set stays where it is.
        XCTAssertEqual(BackupChecklist.move(sets, to: root.appending(path: "elsewhere")), sets)
    }

    func testRetiredSetComesBackInTheSameFolderWithoutDuplicates() {
        let codex = root.appending(path: "codex")
        let elsewhere = root.appending(path: "elsewhere")
        let set = codexSet(codex)
        let away = BackupChecklist.move([set], to: elsewhere)
        XCTAssertEqual(away.count, 2)
        let back = BackupChecklist.move(away, to: drive)
        XCTAssertEqual(back.count, 2, "the earlier set in that folder is reused")
        XCTAssertEqual(back.filter { !$0.retired }.map(\.id), [set.id])
    }
}
