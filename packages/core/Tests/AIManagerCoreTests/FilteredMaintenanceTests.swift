import Foundation
import XCTest
@testable import AIManagerCore

final class FilteredMaintenanceTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: URL!
    private var destination: URL!
    private let old = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/switch-work1-build-oc/test-data/\(UUID().uuidString)")
        home = root.appending(path: "home")
        destination = root.appending(path: "destination")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func write(_ path: String, _ data: Data) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }

    private func jsonl(_ path: String, _ records: [[String: Any]]) throws {
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try write(path, data)
    }

    private func codex(_ path: String, project: String, title: String) throws {
        try jsonl(path, [
            ["type": "session_meta", "payload": ["id": path, "cwd": project, "source": "cli", "originator": "codex-tui"]],
            ["timestamp": "2023-11-14T21:00:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": title]],
            ["timestamp": "2023-11-14T22:00:00Z", "type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "RESPONSE MUST STAY OUT"]]]],
        ])
    }

    private func source(_ tool: CleanupTool = .codex) -> CleanupSource {
        CleanupSource(id: tool.rawValue, tool: tool, title: tool.rawValue, detail: "", providerID: .codex,
            home: home, userHome: root)
    }

    func testCombinedFiltersAndRecoverableDeletion() async throws {
        try codex("sessions/one.jsonl", project: "/Projects/One", title: "Fix export")
        try codex("archived_sessions/two.jsonl", project: "/Projects/Two", title: "Fix export")
        try codex("sessions/three.jsonl", project: "/Projects/One", title: "Keep layout")
        try codex("sessions/recent.jsonl", project: "/Projects/One", title: "Fix export")
        try fm.setAttributes([.modificationDate: old.addingTimeInterval(86_400)], ofItemAtPath: home.appending(path: "sessions/recent.jsonl").path)
        try codex("sessions/active.jsonl", project: "/Projects/One", title: "Fix export")
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: home.appending(path: "sessions/active.jsonl").path)
        try write("auth.json", Data("synthetic login".utf8))
        let scan = try CleanupScanner(source: source(), processes: [], openFiles: []).scan()
        let conversations = scan.categories.filter { ["conversations", "archived"].contains($0.id) }.flatMap(\.items)
        let filter = ConversationCleanupFilter(olderThan: old.addingTimeInterval(1), projects: ["/Projects/One"], title: "EXPORT")
        let selected = conversations.filter(filter.matches)
        XCTAssertEqual(selected.map(\.path), ["sessions/one.jsonl"])
        XCTAssertEqual(conversations.filter(ConversationCleanupFilter(projects: ["/Projects/One", "/Projects/Two"], title: "export").matches).count, 3)
        XCTAssertEqual(conversations.filter(ConversationCleanupFilter(olderThan: old).matches).count, 0, "Before is exclusive")
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"), credentialStore: root.appending(path: "vault"),
            defaultHome: home, sharedRoot: home, orcaAccountsRoot: root.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"), isolationRoot: root)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.reviewCleanup(source(), selected)
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.bytes, selected[0].bytes)
        for state: WriterState in [.active, .unknown] {
            let blocked = try AccountManager(paths: paths, writerCheck: { _ in state })
            do { _ = try await blocked.moveToCleanupTrash(source(), plan) { _ in }; XCTFail("Writer guard skipped") }
            catch { XCTAssertTrue(fm.fileExists(atPath: home.appending(path: "sessions/one.jsonl").path)) }
        }
        let batch = try await manager.moveToCleanupTrash(source(), plan) { _ in }
        XCTAssertFalse(fm.fileExists(atPath: home.appending(path: "sessions/one.jsonl").path))
        for path in ["archived_sessions/two.jsonl", "sessions/three.jsonl", "sessions/recent.jsonl", "sessions/active.jsonl", "auth.json"] {
            XCTAssertTrue(fm.fileExists(atPath: home.appending(path: path).path), path)
        }
        try await manager.restoreCleanupTrash(source(), batch.id)
        XCTAssertTrue(fm.fileExists(atPath: home.appending(path: "sessions/one.jsonl").path))
    }

    func testProjectFiltersKeepTheRecordedFolderInsteadOfGuessingDashes() throws {
        let data = Data("{\"cwd\": \"/Projects/my-app\", \"message\": {\"role\": \"user\", \"content\": \"Owner prompt\"}}\n".utf8)
        try write("projects/-Projects-my-app/one.jsonl", data)
        try write("sessions/-Projects-my-app/one.jsonl", data)
        for tool: CleanupTool in [.claude, .droid] {
            let scan = try CleanupScanner(source: source(tool), processes: [], openFiles: []).scan()
            let items = try XCTUnwrap(scan.categories.first { $0.id == "conversations" }?.items)
            XCTAssertEqual(items.map(\.project), ["/Projects/my-app"])
            XCTAssertEqual(items.filter(ConversationCleanupFilter(projects: ["/Projects/my-app"]).matches).count, 1)
        }
    }

    func testAppSourceLimitsFilterScopeAndActiveOrChangedFilesStay() throws {
        try codex("sessions/one.jsonl", project: "/Projects/One", title: "Fix export")
        try jsonl("projects/-Projects-One/claude.jsonl", [["cwd": "/Projects/One", "message": ["role": "user", "content": "Fix Claude"]]])
        let codexScan = try CleanupScanner(source: source(), processes: [], openFiles: []).scan()
        let claudeScan = try CleanupScanner(source: source(.claude), processes: [], openFiles: []).scan()
        XCTAssertEqual(codexScan.categories.first { $0.id == "conversations" }?.items.map(\.title), ["Fix export"])
        XCTAssertEqual(claudeScan.categories.first { $0.id == "conversations" }?.items.map(\.title), ["Fix Claude"])
        let item = try XCTUnwrap(codexScan.categories.first { $0.id == "conversations" }?.selectable.first)
        let cleanup = ConversationCleanup(home: home, userHome: root)
        let plan = try cleanup.review([item])
        try write("sessions/one.jsonl", Data("changed".utf8))
        XCTAssertThrowsError(try cleanup.moveToTrash(plan))
        XCTAssertTrue(fm.fileExists(atPath: home.appending(path: "sessions/one.jsonl").path))
        XCTAssertFalse(ConversationCleanupFilter().matches(item.protecting("In use now.")))
    }

    private func backupSet(_ service: BackupSource.Service) -> BackupSet {
        BackupSet(name: service.rawValue, source: BackupSource(id: service.rawValue, service: service, home: home),
            items: BackupPresets.items(for: service), destination: destination, includeLogins: true, keep: 1, promptsOnly: true)
    }

    func testPromptBackupLayoutRolesOrderingRetentionAndRestore() async throws {
        try codex("sessions/one.jsonl", project: "/Projects/One", title: "First owner prompt")
        try codex("sessions/two.jsonl", project: "/Elsewhere/One", title: "Second owner prompt")
        try jsonl("sessions/ordered.jsonl", [
            ["type": "session_meta", "payload": ["cwd": "/Projects/One"]],
            ["timestamp": "2023-11-14T22:00:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "Later prompt"]],
            ["timestamp": "2023-11-14T21:00:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "Earlier prompt"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Earlier prompt"]]]],
            ["type": "response_item", "payload": ["type": "function_call_output", "output": "TOOL MUST STAY OUT"]],
        ])
        try write("auth.json", Data("AUTH MUST STAY OUT".utf8))
        try write("config.toml", Data("CONFIG MUST STAY OUT".utf8))
        let engine = BackupEngine(applicationSupport: root.appending(path: "support"))
        let set = backupSet(.codex)
        try await engine.saveSets([set])
        let saved = try await engine.sets()
        XCTAssertEqual(saved.first?.promptsOnly, true)
        let first = try await engine.snapshot(set)
        XCTAssertEqual(first.manifest.promptsOnly, true)
        XCTAssertTrue(first.manifest.skipped.isEmpty)
        XCTAssertEqual(first.files, 4, "Three conversations and the index")
        let entries = first.manifest.entries.filter { $0.path != "prompts/index.md" }
        XCTAssertEqual(Set(entries.map { $0.path.split(separator: "/")[1] }).count, 2, "Same project name with different paths stays separate")
        for entry in first.manifest.entries {
            XCTAssertTrue(entry.path.hasPrefix("prompts/") && entry.path.hasSuffix(".md"))
            let text = try String(contentsOf: first.folder.appending(path: "files/" + entry.path), encoding: .utf8)
            for excluded in ["RESPONSE MUST STAY OUT", "TOOL MUST STAY OUT", "AUTH MUST STAY OUT", "CONFIG MUST STAY OUT"] {
                XCTAssertFalse(text.contains(excluded))
            }
            if text.contains("## 2023-11-14T22:00:00Z") {
                let body = String(text[try XCTUnwrap(text.range(of: "\n## ")?.lowerBound)...])
                XCTAssertLessThan(try XCTUnwrap(body.range(of: "Earlier prompt")?.lowerBound), try XCTUnwrap(body.range(of: "Later prompt")?.lowerBound))
                XCTAssertEqual(body.components(separatedBy: "Earlier prompt").count - 1, 1)
            }
        }
        let second = try await engine.snapshot(set)
        XCTAssertEqual(second.newBytes, 0)
        let status = try await engine.status(for: set)
        XCTAssertEqual(status.snapshots.count, 1)
        do { _ = try await engine.restore(second, set: set); XCTFail("Prompt snapshot restored over live data") } catch {}
        let output = root.appending(path: "restore")
        let restored = try await engine.restore(second, set: set, to: output)
        XCTAssertEqual(restored.restored, 4)
        XCTAssertTrue(fm.fileExists(atPath: output.appending(path: "prompts/index.md").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appending(path: "auth.json").path))
    }

    func testOtherToolsExportUserTextAndProfilesOnly() async throws {
        let records: [[String: Any]] = [
            ["cwd": "/Projects/Owner", "timestamp": "2023-11-14T21:00:00Z", "message": ["role": "user", "content": [["type": "text", "text": "Owner text"], ["type": "tool_result", "content": "TOOL OUTPUT"]]]],
            ["isMeta": true, "message": ["role": "user", "content": "META"]],
            ["message": ["role": "assistant", "content": "RESPONSE"]],
            ["message": ["role": "user", "content": [["type": "tool_result", "content": "TOOL OUTPUT"]]]],
        ]
        try jsonl("projects/-Projects-Owner/one.jsonl", records)
        try jsonl("sessions/-Projects-Owner/one.jsonl", records)
        for service: BackupSource.Service in [.claude, .droid, .grok, .gemini] {
            if service == .grok {
                try jsonl("sessions/%2FProjects%2FOwner/session/updates.jsonl", [
                    ["timestamp": "2023-11-14T21:00:00Z", "method": "session/update", "params": ["update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "Owner "]]]],
                    ["method": "session/update", "params": ["update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "text"]]]],
                    ["method": "session/update", "params": ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "RESPONSE"]]]],
                ])
                try jsonl("sessions/%2FProjects%2FOwner/session/chat_history.jsonl", [["type": "user", "content": [["type": "text", "text": "DUPLICATE"]]]])
            } else if service == .gemini {
                try write("tmp/project/chats/session.json", JSONSerialization.data(withJSONObject: ["cwd": "/Projects/Owner", "messages": records]))
            }
            let engine = BackupEngine(applicationSupport: root.appending(path: "support-" + service.rawValue))
            var set = backupSet(service)
            if service == .claude {
                let profile = home.appending(path: "profile")
                try jsonl("profile/sessions/own.jsonl", records)
                set.profiles = ["own": profile]
                set.items.append(BackupItem("_profiles/own/sessions"))
            }
            let snapshot = try await engine.snapshot(set)
            XCTAssertTrue(snapshot.manifest.skipped.isEmpty, service.rawValue)
            let docs = snapshot.manifest.entries.filter { $0.path != "prompts/index.md" }
            XCTAssertEqual(docs.count, service == .claude ? 2 : 1, service.rawValue)
            for entry in docs {
                let text = try String(contentsOf: snapshot.folder.appending(path: "files/" + entry.path), encoding: .utf8)
                XCTAssertTrue(text.contains("Owner text"))
                XCTAssertTrue(text.contains("Project: /Projects/Owner"))
                for excluded in ["TOOL OUTPUT", "RESPONSE", "META", "DUPLICATE"] { XCTAssertFalse(text.contains(excluded)) }
            }
        }
    }

    func testGrokHistoryFallbackExcludesSyntheticUserMessages() async throws {
        try jsonl("sessions/%2FProjects%2FOwner/session/chat_history.jsonl", [
            ["type": "user", "content": [["type": "text", "text": "Owner prompt"]]],
            ["type": "user", "synthetic_reason": "system_reminder", "content": [["type": "text", "text": "INJECTED"]]],
            ["type": "assistant", "content": "RESPONSE"],
            ["type": "tool_result", "content": "TOOL"],
        ])
        let engine = BackupEngine(applicationSupport: root.appending(path: "support"))
        let snapshot = try await engine.snapshot(backupSet(.grok))
        let entry = try XCTUnwrap(snapshot.manifest.entries.first { $0.path != "prompts/index.md" })
        let text = try String(contentsOf: snapshot.folder.appending(path: "files/" + entry.path), encoding: .utf8)
        XCTAssertTrue(text.contains("Owner prompt") && text.contains("Unknown time"))
        for excluded in ["INJECTED", "RESPONSE", "TOOL"] { XCTAssertFalse(text.contains(excluded)) }
        XCTAssertEqual(snapshot.files, 2)
    }

    func testOldSetsDecodeAndFullRestoreStillMakesAFullSafetyCopy() async throws {
        try codex("sessions/one.jsonl", project: "/Projects/One", title: "Owner prompt")
        try write("config.toml", Data("old config".utf8))
        var set = backupSet(.codex)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(set)) as? [String: Any])
        object.removeValue(forKey: "promptsOnly")
        let legacy = try JSONDecoder().decode(BackupSet.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(legacy.promptsOnly)
        set.promptsOnly = false
        set.keep = 3
        let engine = BackupEngine(applicationSupport: root.appending(path: "support"))
        let full = try await engine.snapshot(set)
        try write("config.toml", Data("new config".utf8))
        set.promptsOnly = true
        let restored = try await engine.restore(full, set: set)
        let safety = try XCTUnwrap(restored.safetySnapshot)
        XCTAssertNotEqual(safety.manifest.promptsOnly, true)
        XCTAssertEqual(try String(contentsOf: safety.folder.appending(path: "files/config.toml"), encoding: .utf8), "new config")
        XCTAssertEqual(try String(contentsOf: home.appending(path: "config.toml"), encoding: .utf8), "old config")
    }

    func testPromptBackupSkipsLinksAndReportsMalformedTranscripts() async throws {
        try codex("sessions/one.jsonl", project: "/Projects/One", title: "Owner prompt")
        try write("auth.json", Data("PRIVATE".utf8))
        try fm.createSymbolicLink(at: home.appending(path: "sessions/link.jsonl"), withDestinationURL: home.appending(path: "auth.json"))
        try write("sessions/broken.jsonl", Data("not json\n".utf8))
        let engine = BackupEngine(applicationSupport: root.appending(path: "support"))
        let snapshot = try await engine.snapshot(backupSet(.codex))
        XCTAssertEqual(snapshot.files, 2)
        XCTAssertTrue(snapshot.manifest.skipped.contains { $0.hasSuffix("broken.jsonl") })
        XCTAssertFalse(snapshot.manifest.entries.contains { $0.path.contains("link") })
    }
}
