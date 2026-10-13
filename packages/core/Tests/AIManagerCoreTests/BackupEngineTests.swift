import Foundation
import XCTest
@testable import AIManagerCore

final class BackupEngineTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: URL!
    private var dest: URL!
    private var engine: BackupEngine!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "switch-backup-\(UUID().uuidString)").resolvingSymlinksInPath()
        home = root.appending(path: "home")
        dest = root.appending(path: "dest")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        engine = BackupEngine(applicationSupport: root.appending(path: "support"))
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func write(_ path: String, _ text: String, mode: Int = 0o644) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func makeSet(name: String = "Codex", items: [String] = ["sessions", "config.toml"], logins: [String] = [],
                         includeLogins: Bool = false, keep: Int = 10) -> BackupSet {
        BackupSet(name: name, source: BackupSource(id: "codex", service: .codex, home: home),
                  items: items.map { BackupItem($0) } + logins.map { BackupItem($0, isLogin: true) },
                  destination: dest, includeLogins: includeLogins, keep: keep)
    }

    private func inode(_ url: URL) throws -> UInt64 {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return UInt64(info.st_ino)
    }

    private func entry(_ snapshot: BackupSnapshot, _ path: String) throws -> BackupManifest.Entry {
        try XCTUnwrap(snapshot.manifest.entries.first { $0.path == path })
    }

    func testFirstSnapshotCopiesEverythingWithMatchingHashes() async throws {
        try write("sessions/a.jsonl", "alpha")
        try write("sessions/deep/b.jsonl", "beta beta")
        try write("config.toml", "model = 1")
        let set = makeSet()
        let snapshot = try await engine.snapshot(set)
        XCTAssertEqual(snapshot.files, 3)
        XCTAssertEqual(snapshot.totalBytes, 5 + 9 + 9)
        XCTAssertEqual(snapshot.newBytes, snapshot.totalBytes)
        XCTAssertTrue(snapshot.manifest.skipped.isEmpty)
        for item in snapshot.manifest.entries where item.kind == .file {
            let copy = snapshot.folder.appending(path: "files/" + item.path)
            XCTAssertEqual(try CoreSupport.digest(file: copy), item.sha256)
            XCTAssertEqual(try CoreSupport.digest(file: home.appending(path: item.path)), item.sha256)
        }
        let status = try await engine.status(for: set)
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.snapshots.count, 1)
        XCTAssertTrue(snapshot.folder.path.contains("/Switch Backups/Codex/"))
    }

    func testSecondSnapshotSharesUnchangedFilesAndCopiesOnlyChanges() async throws {
        try write("sessions/same.jsonl", String(repeating: "x", count: 4_000))
        try write("sessions/edit.jsonl", "one")
        let set = makeSet()
        let first = try await engine.snapshot(set)
        try write("sessions/edit.jsonl", "two-longer")
        try write("sessions/new.jsonl", "fresh")
        let second = try await engine.snapshot(set)
        XCTAssertNotEqual(first.folder, second.folder)
        XCTAssertEqual(second.files, 3)
        XCTAssertEqual(second.newBytes, Int64("two-longer".count + "fresh".count))
        XCTAssertEqual(try inode(first.folder.appending(path: "files/sessions/same.jsonl")),
                       try inode(second.folder.appending(path: "files/sessions/same.jsonl")))
        XCTAssertNotEqual(try inode(first.folder.appending(path: "files/sessions/edit.jsonl")),
                          try inode(second.folder.appending(path: "files/sessions/edit.jsonl")))
        XCTAssertEqual(try String(contentsOf: first.folder.appending(path: "files/sessions/edit.jsonl"), encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: second.folder.appending(path: "files/sessions/edit.jsonl"), encoding: .utf8), "two-longer")
        XCTAssertEqual(try entry(second, "sessions/same.jsonl").sha256, try entry(first, "sessions/same.jsonl").sha256)
        XCTAssertEqual(try entry(second, "sessions/edit.jsonl").sha256, CoreSupport.digest(Data("two-longer".utf8)))
    }

    func testLoginFilesAreExcludedUnlessIncluded() async throws {
        try write("config.toml", "model = 1")
        try write("auth.json", "{\"token\":\"synthetic\"}", mode: 0o600)
        try write("sessions/oauth_creds.json", "synthetic")
        let without = try await engine.snapshot(makeSet(logins: ["auth.json"]))
        XCTAssertEqual(without.manifest.entries.map(\.path).sorted(), ["config.toml", "sessions"])
        XCTAssertFalse(without.manifest.entries.contains { $0.path == "auth.json" || $0.path.hasSuffix("oauth_creds.json") })
        XCTAssertFalse(fm.fileExists(atPath: without.folder.appending(path: "files/auth.json").path))

        let with = try await engine.snapshot(makeSet(name: "WithLogins", logins: ["auth.json"], includeLogins: true))
        XCTAssertTrue(with.manifest.entries.contains { $0.path == "auth.json" })
        XCTAssertTrue(with.manifest.entries.contains { $0.path == "sessions/oauth_creds.json" })
    }

    func testPresetsMarkLoginItems() {
        for service in BackupSource.Service.allCases {
            let items = BackupPresets.items(for: service)
            XCTAssertTrue(items.contains { !$0.isLogin }, "\(service)")
            XCTAssertTrue(items.contains { $0.isLogin }, "\(service)")
        }
        XCTAssertTrue(BackupPresets.isLogin("auth.v2.key"))
        XCTAssertTrue(BackupPresets.isLogin("a/.credentials.json"))
        XCTAssertFalse(BackupPresets.isLogin("sessions/a.jsonl"))
    }

    func testSymbolicLinksAreStoredNotFollowed() async throws {
        let outside = root.appending(path: "outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appending(path: "leak.txt"))
        try write("sessions/a.jsonl", "a")
        try fm.createSymbolicLink(atPath: home.appending(path: "sessions/out").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: home.appending(path: "config.toml").path, withDestinationPath: outside.appending(path: "leak.txt").path)
        let snapshot = try await engine.snapshot(makeSet())
        let link = try entry(snapshot, "sessions/out")
        XCTAssertEqual(link.kind, .symlink)
        XCTAssertEqual(link.linkTarget, outside.path)
        XCTAssertFalse(snapshot.manifest.entries.contains { $0.path.hasSuffix("leak.txt") })
        var info = stat()
        XCTAssertEqual(lstat(snapshot.folder.appending(path: "files/sessions/out").path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try entry(snapshot, "config.toml").kind, .symlink)
    }

    func testPermissionsAreKept() async throws {
        try write("sessions/private.jsonl", "p", mode: 0o600)
        try write("config.toml", "c", mode: 0o644)
        let set = makeSet()
        let snapshot = try await engine.snapshot(set)
        func mode(_ url: URL) throws -> Int { (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
        XCTAssertEqual(try mode(snapshot.folder.appending(path: "files/sessions/private.jsonl")), 0o600)
        XCTAssertEqual(try mode(snapshot.folder.appending(path: "files/config.toml")), 0o644)
        XCTAssertEqual(try mode(snapshot.folder), 0o700)
        XCTAssertEqual(try mode(dest.appending(path: "Switch Backups/Codex")), 0o700)
        let second = try await engine.snapshot(set)
        XCTAssertEqual(try mode(second.folder.appending(path: "files/sessions/private.jsonl")), 0o600)
    }

    func testSpecialFilesAreSkippedSilently() async throws {
        try write("sessions/a.jsonl", "a")
        XCTAssertEqual(mkfifo(home.appending(path: "sessions/pipe").path, 0o600), 0)
        let snapshot = try await engine.snapshot(makeSet())
        XCTAssertFalse(snapshot.manifest.entries.contains { $0.path.hasSuffix("pipe") })
        XCTAssertTrue(snapshot.manifest.skipped.isEmpty)
    }

    func testInterruptedSnapshotIsCleanedAndNeverListed() async throws {
        try write("sessions/a.jsonl", "a")
        let set = makeSet()
        _ = try await engine.snapshot(set)
        let base = dest.appending(path: "Switch Backups/Codex")
        let own = base.appending(path: ".in-progress-crashed")
        try fm.createDirectory(at: own, withIntermediateDirectories: true)
        try Data(set.id.uuidString.utf8).write(to: own.appending(path: BackupEngine.markerName))
        try Data("partial".utf8).write(to: own.appending(path: "files-partial"))
        let foreign = base.appending(path: ".in-progress-foreign")
        try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("not ours".utf8).write(to: foreign.appending(path: "keep.txt"))
        let beforeStatus = try await engine.status(for: set)
        XCTAssertEqual(beforeStatus.snapshots.count, 1)
        _ = try await engine.snapshot(set)
        XCTAssertFalse(fm.fileExists(atPath: own.path))
        XCTAssertTrue(fm.fileExists(atPath: foreign.appending(path: "keep.txt").path))
        let afterStatus = try await engine.status(for: set)
        XCTAssertEqual(afterStatus.snapshots.count, 2)
    }

    func testRestoreToAnotherFolderRestoresWholeSnapshotAndChosenItems() async throws {
        try write("sessions/a.jsonl", "alpha", mode: 0o600)
        try write("sessions/b.jsonl", "beta")
        try write("config.toml", "model = 1")
        let set = makeSet()
        let snapshot = try await engine.snapshot(set)
        let whole = root.appending(path: "restored-all")
        let result = try await engine.restore(snapshot, set: set, to: whole)
        XCTAssertEqual(result.restored, 3)
        XCTAssertNil(result.safetySnapshot)
        XCTAssertEqual(try String(contentsOf: whole.appending(path: "sessions/a.jsonl"), encoding: .utf8), "alpha")
        XCTAssertEqual((try fm.attributesOfItem(atPath: whole.appending(path: "sessions/a.jsonl").path)[.posixPermissions] as! NSNumber).intValue, 0o600)

        let chosen = root.appending(path: "restored-some")
        let some = try await engine.restore(snapshot, set: set, items: ["sessions/b.jsonl"], to: chosen)
        XCTAssertEqual(some.restored, 1)
        XCTAssertTrue(fm.fileExists(atPath: chosen.appending(path: "sessions/b.jsonl").path))
        XCTAssertFalse(fm.fileExists(atPath: chosen.appending(path: "sessions/a.jsonl").path))
        XCTAssertFalse(fm.fileExists(atPath: chosen.appending(path: "config.toml").path))
    }

    func testRestoreInPlaceTakesSafetySnapshotAndKeepsExtraFiles() async throws {
        try write("sessions/a.jsonl", "original")
        try write("config.toml", "model = 1")
        let set = makeSet()
        let snapshot = try await engine.snapshot(set)
        try write("sessions/a.jsonl", "edited later!")
        try write("sessions/only-now.jsonl", "extra")
        let result = try await engine.restore(snapshot, set: set)
        XCTAssertEqual(try String(contentsOf: home.appending(path: "sessions/a.jsonl"), encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: home.appending(path: "sessions/only-now.jsonl"), encoding: .utf8), "extra")
        XCTAssertEqual(result.extraFiles, ["sessions/only-now.jsonl"])
        let safety = try XCTUnwrap(result.safetySnapshot)
        XCTAssertTrue(safety.manifest.safety)
        XCTAssertEqual(try String(contentsOf: safety.folder.appending(path: "files/sessions/a.jsonl"), encoding: .utf8), "edited later!")
        XCTAssertTrue(safety.date >= snapshot.date)
        let listed = try await engine.status(for: set).snapshots
        XCTAssertEqual(listed.count, 2)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: home.appending(path: "sessions").path).allSatisfy { !$0.hasPrefix(".switch-restore-") })
    }

    func testPruneKeepsNewestAndDeletesOnlyOwnSnapshots() async throws {
        try write("sessions/a.jsonl", "a")
        let set = makeSet(keep: 2)
        let base = dest.appending(path: "Switch Backups/Codex")
        var made: [BackupSnapshot] = []
        for round in 0..<4 {
            try write("sessions/a.jsonl", "round \(round)")
            made.append(try await engine.snapshot(set))
        }
        let stranger = base.appending(path: "notes")
        try fm.createDirectory(at: stranger, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: stranger.appending(path: "keep.txt"))
        let sibling = dest.appending(path: "Switch Backups/Other")
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        try await engine.prune(set)
        let kept = try await engine.status(for: set).snapshots
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(Set(kept.map(\.id)), Set(made.suffix(2).map(\.id)))
        XCTAssertTrue(fm.fileExists(atPath: stranger.appending(path: "keep.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: sibling.path))
        XCTAssertFalse(fm.fileExists(atPath: made[0].folder.path))
        // The newest snapshot stays complete after older ones go: hard links survive.
        XCTAssertEqual(try String(contentsOf: made[3].folder.appending(path: "files/sessions/a.jsonl"), encoding: .utf8), "round 3")
    }

    func testMissingVolumeWaitsAndCreatesNothing() async throws {
        let volume = "SwitchMissingDrive-\(UUID().uuidString)"
        var set = makeSet()
        set.destination = URL(fileURLWithPath: "/Volumes/\(volume)/Backups")
        try write("config.toml", "x")
        let status = try await engine.status(for: set)
        XCTAssertEqual(status.state, .waiting(volume))
        do {
            _ = try await engine.snapshot(set)
            XCTFail("expected waiting")
        } catch BackupError.waiting(let name) {
            XCTAssertEqual(name, volume)
            XCTAssertTrue(BackupError.waiting(name).localizedDescription.contains("Waiting for \(volume)"))
        }
        XCTAssertFalse(fm.fileExists(atPath: "/Volumes/\(volume)"))
        let again = try await engine.status(for: set)
        XCTAssertNotNil(again.lastError)
    }

    func testOverlappingSourceAndDestinationAreRefused() async throws {
        var set = makeSet()
        set.destination = home.appending(path: "sessions")
        try fm.createDirectory(at: set.destination, withIntermediateDirectories: true)
        do { _ = try await engine.snapshot(set); XCTFail("expected refusal") } catch BackupError.unsafe {}
    }

    func testSetsPersistOwnerPrivate() async throws {
        let set = makeSet(logins: ["auth.json"])
        try await engine.saveSets([set])
        let loaded = try await engine.sets()
        XCTAssertEqual(loaded.map(\.id), [set.id])
        XCTAssertEqual(loaded.first?.items.filter(\.isLogin).map(\.path), ["auth.json"])
        let file = root.appending(path: "support/backup-sets.json")
        XCTAssertEqual((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue, 0o600)
    }

    func testScheduleReportsNextDue() async throws {
        try write("config.toml", "x")
        var set = makeSet()
        set.schedule = .daily
        let now = Date()
        let none = try await engine.status(for: set, now: now)
        XCTAssertEqual(none.nextDue, now)
        let snapshot = try await engine.snapshot(set)
        let next = try await engine.status(for: set, now: now).nextDue
        XCTAssertEqual(next, snapshot.date.addingTimeInterval(86_400))
        set.schedule = .off
        let off = try await engine.status(for: set)
        XCTAssertNil(off.nextDue)
    }

    func testCancelledSnapshotLeavesNothingListed() async throws {
        for index in 0..<300 { try write("sessions/f\(index).jsonl", String(repeating: "z", count: 2_000)) }
        let set = makeSet()
        let engine = self.engine!
        let task = Task { try await engine.snapshot(set) }
        task.cancel()
        _ = await task.result
        let listed = try await engine.status(for: set).snapshots
        XCTAssertTrue(listed.count <= 1)
        let base = dest.appending(path: "Switch Backups/Codex")
        if fm.fileExists(atPath: base.path) {
            // Any in-progress folder left behind is not listed and the next run removes it.
            _ = try await engine.snapshot(set)
            XCTAssertTrue(try fm.contentsOfDirectory(atPath: base.path).allSatisfy { !$0.hasPrefix(".in-progress-") })
        }
    }

    func testLargeTreeSnapshotIsQuickAndSecondRunLinksEverything() async throws {
        for index in 0..<2_000 {
            try write("sessions/d\(index % 20)/f\(index).jsonl", "line \(index)\n")
        }
        let set = makeSet()
        let clock = ContinuousClock()
        var first: BackupSnapshot!
        let fullTime = try await clock.measure { first = try await engine.snapshot(set) }
        XCTAssertEqual(first.files, 2_000)
        var second: BackupSnapshot!
        let incrementalTime = try await clock.measure { second = try await engine.snapshot(set) }
        XCTAssertEqual(second.files, 2_000)
        XCTAssertEqual(second.newBytes, 0)
        print("BACKUP TIMING 2000 files: full \(fullTime), incremental \(incrementalTime)")
        XCTAssertLessThan(fullTime, .seconds(30))
        XCTAssertLessThan(incrementalTime, .seconds(30))
    }
}
