import Foundation
import XCTest
#if canImport(ImageIO)
import ImageIO
#endif
@testable import AIManagerCore

/// Cleanup: old app versions, the Claude app VM, pasted images, and the single Claude Code source.
final class CleanupVersionsAndImagesTests: XCTestCase {
    private var root: URL!
    private var user: URL!
    private let files = FileManager.default
    private let longAgo = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appending(path: "CleanupVersionsAndImagesTests-\(UUID().uuidString)")
        user = root.appending(path: "user")
        try CoreSupport.privateDirectory(user, fileManager: files)
    }

    override func tearDownWithError() throws {
        if let root { try? files.removeItem(at: root) }
    }

    private func source(_ tool: CleanupTool, home: URL, extra: [URL] = []) -> CleanupSource {
        CleanupSource(id: tool.rawValue, tool: tool, title: tool.rawValue, detail: "", providerID: .codex,
            home: home, userHome: user, extraHomes: extra)
    }

    private func scan(_ tool: CleanupTool, home: URL, extra: [URL] = [], processes: [String] = [], open: [String] = []) throws -> CleanupScan {
        try CleanupScanner(source: source(tool, home: home, extra: extra), now: Date().addingTimeInterval(3_600),
            processes: processes, openFiles: open).scan()
    }

    private func category(_ scan: CleanupScan, _ id: String) -> CleanupCategory? { scan.categories.first { $0.id == id } }

    private func put(_ base: URL, _ path: String, _ text: String = "x", age: Date? = nil) throws {
        let url = base.appending(path: path)
        try CoreSupport.atomicWrite(Data(text.utf8), to: url, permissions: 0o644, fileManager: files)
        if let age { try files.setAttributes([.modificationDate: age], ofItemAtPath: url.path) }
    }

    // MARK: Old versions

    func testCodexKeepsTheCurrentAndRunningReleasesAndListsTheRest() throws {
        let codex = root.appending(path: "codex")
        for (set, names) in [("standalone", ["0.1", "0.2", "0.3", "0.4"]), ("app-server-daemon", ["1.0", "1.1"])] {
            for name in names { try put(codex, "packages/\(set)/releases/\(name)/codex", name, age: longAgo) }
        }
        try files.createSymbolicLink(at: codex.appending(path: "packages/standalone/current"),
            withDestinationURL: codex.appending(path: "packages/standalone/releases/0.3"))
        try files.createSymbolicLink(at: codex.appending(path: "packages/app-server-daemon/current"),
            withDestinationURL: codex.appending(path: "packages/app-server-daemon/releases/1.1"))
        let running = CoreSupport.canonical(codex.appending(path: "packages/standalone/releases/0.4")).path + "/codex"
        let versions = try XCTUnwrap(category(try scan(.codex, home: codex, processes: [running]), "versions"))
        XCTAssertFalse(versions.ageBased)
        XCTAssertTrue(versions.preselected)
        XCTAssertEqual(versions.selectable.map(\.path).sorted(),
            ["packages/app-server-daemon/releases/1.0", "packages/standalone/releases/0.1", "packages/standalone/releases/0.2"],
            "The current builds stay and a release a running process uses is protected")
        XCTAssertEqual(versions.protectedItems.map(\.path), ["packages/standalone/releases/0.4"])
        XCTAssertEqual(versions.items.first { $0.path.hasSuffix("0.1") }?.title, "Standalone 0.1")
    }

    func testClaudeVersionsKeepTheLauncherTargetRunningBuildsAndTheNewestDesktopCopy() throws {
        let claude = root.appending(path: "claude")
        try CoreSupport.privateDirectory(claude, fileManager: files)
        for name in ["2.1.9", "2.1.10", "2.1.11", "2.1.12"] { try put(user, ".local/share/claude/versions/\(name)", name, age: longAgo) }
        try files.createDirectory(at: user.appending(path: ".local/bin"), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: user.appending(path: ".local/bin/claude"),
            withDestinationURL: user.appending(path: ".local/share/claude/versions/2.1.12"))
        for name in ["2.1.2", "2.1.10", "2.1.9"] { try put(user, "Library/Application Support/Claude/claude-code/\(name)/claude", name, age: longAgo) }
        let running = CoreSupport.canonical(user).path + "/.local/bin/claude"
        // The running program is named by its link; the scan resolves it, so list the real path too.
        let runningReal = CoreSupport.canonical(user.appending(path: ".local/share/claude/versions/2.1.10")).path
        let versions = try XCTUnwrap(category(try scan(.claude, home: claude, processes: [running, runningReal]), "versions"))
        XCTAssertEqual(versions.selectable.map(\.title).sorted(), ["Claude Code 2.1.11", "Claude Code 2.1.9", "Claude app 2.1.2", "Claude app 2.1.9"])
        XCTAssertEqual(versions.protectedItems.map(\.title), ["Claude Code 2.1.10"])
    }

    func testClaudeAppVMIsUncheckedAndWaitsForTheApp() throws {
        let claude = root.appending(path: "claude")
        try CoreSupport.privateDirectory(claude, fileManager: files)
        try put(user, "Library/Application Support/Claude/claude-code-vm/2.1.246/disk", "vm", age: longAgo)
        let idle = try XCTUnwrap(category(try scan(.claude, home: claude), "claude-vm"))
        XCTAssertFalse(idle.preselected)
        XCTAssertFalse(idle.ageBased)
        XCTAssertEqual(idle.selectable.count, 1)
        let busy = try XCTUnwrap(category(try scan(.claude, home: claude, processes: ["/Applications/Claude.app/Contents/MacOS/Claude"]), "claude-vm"))
        XCTAssertTrue(busy.selectable.isEmpty)
        XCTAssertEqual(busy.protectedItems.first?.protectedReason, "The Claude app is running.")
    }

    // MARK: One Claude Code source

    func testClaudeCodeIsOneSourceWithTheProfilesOwnFilesInside() throws {
        let shared = user.appending(path: ".claude")
        let profile = user.appending(path: "Library/Application Support/AI Manager/claude-code-profiles/ID/config")
        try put(shared, "cache/a", "shared", age: longAgo)
        try put(profile, "cache/own", "own", age: longAgo)
        try files.createSymbolicLink(at: profile.appending(path: "debug"), withDestinationURL: shared.appending(path: "cache"))
        try put(profile, ".claude.json", "login", age: longAgo)
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"), credentialStore: root.appending(path: "vault"),
            defaultHome: user.appending(path: ".codex"), sharedRoot: user.appending(path: ".codex"),
            orcaAccountsRoot: root.appending(path: "orca"), codexExecutable: URL(fileURLWithPath: "/usr/bin/true"), isolationRoot: root)
        let account = AccountRecord(id: UUID(), identity: AccountIdentity(providerID: .claudeCode, email: "c@x.test", authMode: .oauth),
            home: profile, source: profile, importedAt: Date(),
            verification: .init(state: .verifiedLocally, checkedAt: Date(), detail: ""), credentialDigest: "d")
        let sources = CleanupSources.make(paths: paths, accounts: [account])
        let cleanupSources = sources.filter { !$0.isClaudeProfile }
        XCTAssertEqual(cleanupSources.filter { $0.tool == .claude }.count, 1, "Cleanup lists Claude Code once")
        XCTAssertEqual(sources.filter { $0.tool == .claude }.count, 2, "Backup still lists the profile")
        let merged = try XCTUnwrap(cleanupSources.first { $0.tool == .claude })
        XCTAssertEqual(merged.extraHomes.map { CoreSupport.canonical($0).path }, [CoreSupport.canonical(profile).path])
        let found = try scan(.claude, home: shared, extra: merged.extraHomes)
        let cache = try XCTUnwrap(category(found, "caches"))
        XCTAssertEqual(Set(cache.items.map(\.title)), ["a", "own"], "The profile's real files join; its links and login do not")
        XCTAssertFalse(found.categories.flatMap(\.items).contains { $0.path.contains(".claude.json") })
    }

    // MARK: Totals and dates

    func testTotalCountsEveryListedItemOnceAndDatesAreLastActivity() throws {
        let codex = root.appending(path: "codex")
        let old = Date().addingTimeInterval(-90 * 86_400)
        try put(codex, "sessions/2026/a.jsonl", String(repeating: "a", count: 1_000), age: old)
        try put(codex, "log/l.log", String(repeating: "b", count: 500), age: old)
        let found = try scan(.codex, home: codex)
        XCTAssertEqual(found.totalBytes, 1_500)
        let chat = try XCTUnwrap(category(found, "conversations")?.items.first)
        XCTAssertEqual(chat.updatedAt.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1, "A chat is dated by its last write")
    }

    // MARK: Pasted images

    private func payload(_ seed: String) -> String { String(repeating: seed, count: 1_500) }
    private var tinyURL: String { "data:image/png;base64," + ImageStripper.tinyPNG }

    private func codexLines() -> [String] {
        [
            #"{"type":"session_meta","payload":{"cwd":"/Projects/Img","source":"cli"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Look"},{"type":"input_image","image_url":"data:image/png;base64,\#(payload("QUJD"))"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Look","images":["data:image/jpeg;base64,\#(payload("RUZH"))"],"local_images":[]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Use \"data:image/png;base64,AAAA\" in the page"}}"#,
            #"{"timestamp":"2026-09-18T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":123}}}}"#,
        ]
    }

    private func claudeLines() -> [String] {
        [
            #"{"type":"user","cwd":"/Tmp/app","message":{"role":"user","content":[{"type":"text","text":"see é"},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"\#(payload("SUpL"))"}}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"n":1.50}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(payload("TE1O"))"}}]}]}}"#,
        ]
    }

    private func write(_ lines: [String], to url: URL, age: Date? = nil) throws {
        try CoreSupport.atomicWrite(Data((lines.joined(separator: "\n") + "\n").utf8), to: url, permissions: 0o640, fileManager: files)
        try files.setAttributes([.modificationDate: age ?? longAgo], ofItemAtPath: url.path)
    }

    private func lines(_ url: URL) throws -> [String] {
        String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func testTinyPictureIsAValidPNG() throws {
        let data = try XCTUnwrap(Data(base64Encoded: ImageStripper.tinyPNG))
        #if canImport(ImageIO)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let size = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertEqual(size[kCGImagePropertyPixelWidth] as? Int, 1)
        XCTAssertEqual(size[kCGImagePropertyPixelHeight] as? Int, 1)
        #endif
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testCodexPicturesShrinkInPlaceAndTheOriginalGoesToTheTrash() throws {
        let codex = root.appending(path: "codex")
        let transcript = codex.appending(path: "sessions/2026/09/chat.jsonl")
        let original = codexLines()
        try write(original, to: transcript)
        let before = try Data(contentsOf: transcript)
        let found = try scan(.codex, home: codex)
        let images = try XCTUnwrap(category(found, "images"))
        XCTAssertFalse(images.preselected)
        let item = try XCTUnwrap(images.selectable.first)
        XCTAssertNotEqual(item.id, category(found, "conversations")?.items.first?.id, "A rewrite has its own id")
        XCTAssertEqual(found.totalBytes, Int64(before.count), "Rewrites are not counted twice")

        let cleanup = ConversationCleanup(home: codex, userHome: user)
        let plan = try cleanup.review([item])
        let batch = try cleanup.moveToTrash(plan)
        let after = try Data(contentsOf: transcript)
        XCTAssertEqual(item.bytes, Int64(before.count - after.count), "The size shown is the bytes saved")

        let shrunk = try lines(transcript)
        XCTAssertEqual(shrunk.count, original.count)
        for (index, line) in shrunk.enumerated() {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "Line \(index) must parse")
            if index != 1, index != 2 { XCTAssertEqual(line, original[index], "Line \(index) must stay byte for byte the same") }
            _ = object
        }
        let content = try XCTUnwrap(((try JSONSerialization.jsonObject(with: Data(shrunk[1].utf8)) as? [String: Any])?["payload"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, "Look")
        XCTAssertEqual(content[1]["image_url"] as? String, tinyURL)
        let sent = try XCTUnwrap(((try JSONSerialization.jsonObject(with: Data(shrunk[2].utf8)) as? [String: Any])?["payload"] as? [String: Any]))
        XCTAssertEqual(sent["images"] as? [String], [tinyURL])
        XCTAssertEqual(sent["message"] as? String, "Look")

        var info = stat()
        XCTAssertEqual(lstat(transcript.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o640, "Permissions stay")
        XCTAssertEqual(CleanupScanner.modified(info), longAgo.timeIntervalSince1970, accuracy: 0.001, "The modified time stays")
        XCTAssertFalse(files.fileExists(atPath: transcript.deletingLastPathComponent().appending(path: ".chat.jsonl.switch-tmp").path))

        let trashed = codex.appending(path: ".switch-trash/\(batch.id.uuidString)/0/sessions/2026/09/chat.jsonl")
        XCTAssertEqual(try Data(contentsOf: trashed), before, "The original waits in the trash")

        try cleanup.restore(batch.id)
        XCTAssertEqual(try Data(contentsOf: transcript), before, "Restore puts the original back over the copy")
    }

    func testRestoreRefusesWhenTheShrunkChatChanged() throws {
        let codex = root.appending(path: "codex")
        let transcript = codex.appending(path: "sessions/chat.jsonl")
        try write(codexLines(), to: transcript)
        let cleanup = ConversationCleanup(home: codex, userHome: user)
        let item = try XCTUnwrap(category(try scan(.codex, home: codex), "images")?.selectable.first)
        let batch = try cleanup.moveToTrash(try cleanup.review([item]))
        try Data("a newer chat".utf8).write(to: transcript)
        XCTAssertThrowsError(try cleanup.restore(batch.id))
        XCTAssertEqual(try String(contentsOf: transcript, encoding: .utf8), "a newer chat")
    }

    func testClaudePicturesShrinkAndTheMimeTypeBecomesPNG() throws {
        let claude = root.appending(path: "claude")
        let transcript = claude.appending(path: "projects/-Tmp-app/s1.jsonl")
        let original = claudeLines()
        try write(original, to: transcript)
        let item = try XCTUnwrap(category(try scan(.claude, home: claude), "images")?.selectable.first)
        let cleanup = ConversationCleanup(home: claude, userHome: user)
        _ = try cleanup.moveToTrash(try cleanup.review([item]))
        let shrunk = try lines(transcript)
        XCTAssertEqual(shrunk[1], original[1])
        func source(_ line: String, tool: Bool) throws -> [String: Any] {
            let message = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["message"] as? [String: Any])
            var part = try XCTUnwrap((message["content"] as? [[String: Any]])?.last)
            if tool { part = try XCTUnwrap((part["content"] as? [[String: Any]])?.first) }
            return try XCTUnwrap(part["source"] as? [String: Any])
        }
        for (line, tool) in [(shrunk[0], false), (shrunk[2], true)] {
            let image = try source(line, tool: tool)
            XCTAssertEqual(image["type"] as? String, "base64")
            XCTAssertEqual(image["media_type"] as? String, "image/png")
            XCTAssertEqual(image["data"] as? String, ImageStripper.tinyPNG)
        }
        XCTAssertTrue(shrunk[0].hasPrefix(#"{"type":"user","cwd":"/Tmp/app","message":{"role":"user","content":[{"type":"text","text":"see é"},"#),
            "Everything before the picture stays")
    }

    func testOpenAndRecentChatsAreNotRewritten() throws {
        let codex = root.appending(path: "codex")
        let open = codex.appending(path: "sessions/open.jsonl")
        let recent = codex.appending(path: "sessions/recent.jsonl")
        try write(codexLines(), to: open)
        try write(codexLines(), to: recent, age: Date().addingTimeInterval(1_800))
        let found = try XCTUnwrap(category(try scan(.codex, home: codex, open: [CoreSupport.canonical(open).path]), "images"))
        XCTAssertTrue(found.selectable.isEmpty)
        XCTAssertEqual(Set(found.protectedItems.map(\.path)), ["sessions/open.jsonl", "sessions/recent.jsonl"])
        XCTAssertEqual(found.items.first { $0.path.hasSuffix("open.jsonl") }?.protectedReason, "A running app has this chat open.")
        let cleanup = ConversationCleanup(home: codex, userHome: user)
        XCTAssertThrowsError(try cleanup.review(found.items), "A protected item never reaches the trash step")
    }

    func testRemovingAChatAndShrinkingItInOneCleanupIsRefused() throws {
        let codex = root.appending(path: "codex")
        try write(codexLines(), to: codex.appending(path: "sessions/chat.jsonl"))
        let found = try scan(.codex, home: codex)
        let chat = try XCTUnwrap(category(found, "conversations")?.selectable.first)
        let shrink = try XCTUnwrap(category(found, "images")?.selectable.first)
        XCTAssertThrowsError(try ConversationCleanup(home: codex, userHome: user).review([chat, shrink]))
    }

    func testTextThatOnlyLooksLikeAPictureStays() throws {
        let codex = root.appending(path: "codex")
        let line = #"{"type":"event_msg","payload":{"message":"data:image/png;base64,\#(String(repeating: "!", count: 3_000))"}}"#
        let escaped = #"{"type":"event_msg","payload":{"message":"\"data:image/png;base64,\#(String(repeating: "A", count: 3_000))\""}}"#
        try write([line, escaped], to: codex.appending(path: "sessions/text.jsonl"))
        XCTAssertNil(category(try scan(.codex, home: codex), "images"))
    }
}
