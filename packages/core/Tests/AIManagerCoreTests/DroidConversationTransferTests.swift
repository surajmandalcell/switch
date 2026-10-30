import Foundation
import XCTest
@testable import AIManagerCore

final class DroidConversationTransferTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var state: URL!
    private var cwd: URL!
    private let fm = FileManager.default
    private enum Interrupted: Error { case fault }

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        let storage = environment["AGENT_DATA_DIR"] ?? environment["TMPDIR"] ?? fm.temporaryDirectory.path
        root = CoreSupport.canonical(URL(fileURLWithPath: storage))
            .appending(path: "switch/DroidConversationTransferTests-\(UUID())")
        home = root.appending(path: ".factory")
        state = root.appending(path: "support/droid-conversations.json")
        cwd = root.appending(path: "project")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try fm.removeItem(at: root) }
    }

    func testNativeHeaderFullBodyAndRepeatedSwitchReuseOneCopy() throws {
        let original = try session(body: message("Keep the complete conversation.") + message("Including the answer.", role: "assistant"))
        let originalData = try Data(contentsOf: original)
        let body = try transcriptBody(original)
        let account = UUID()
        var ids: [UUID] = []
        let plan = try prepare()
        let report = try plan.transfer(to: account) { id, directory, title in
            XCTAssertEqual(directory.pathComponents, self.cwd.pathComponents)
            XCTAssertEqual(title, "Synthetic conversation")
            ids.append(id)
            _ = try self.session(id: id, organization: "target-org", folder: "native", body: Data())
        }
        XCTAssertEqual(report, .init(transferredCount: 1))
        let target = path(ids[0], folder: "native")
        XCTAssertEqual(try transcriptBody(target), body)
        XCTAssertEqual(try header(target)["organizationId"] as? String, "target-org")
        XCTAssertNotEqual(try header(target)["id"] as? String, try header(original)["id"] as? String)
        XCTAssertEqual(try Data(contentsOf: original), originalData)

        let again = try prepare().transfer(to: account) { _, _, _ in XCTFail("Duplicate native session") }
        XCTAssertEqual(again, .init(transferredCount: 0))
        XCTAssertEqual(try transcriptBody(target), body)
        XCTAssertEqual(try Data(contentsOf: original), originalData)
    }

    func testNewMessagesFollowBothDirectionsAndOriginalNeverChanges() throws {
        let original = try session(body: message("First request."))
        let originalData = try Data(contentsOf: original)
        let firstAccount = UUID(), secondAccount = UUID()
        var firstID: UUID!, secondID: UUID!
        XCTAssertEqual(try prepare().transfer(to: secondAccount) { id, _, _ in
            secondID = id
            _ = try self.session(id: id, organization: "second-org", folder: "native", body: Data())
        }.transferredCount, 1)
        let second = path(secondID, folder: "native")
        try append(message("Continue on the second account."), to: second)

        XCTAssertEqual(try prepare(sourceAccountID: secondAccount).transfer(to: firstAccount) { id, _, _ in
            firstID = id
            _ = try self.session(id: id, organization: "first-org", folder: "native", body: Data())
        }.transferredCount, 1)
        let first = path(firstID, folder: "native")
        XCTAssertEqual(try transcriptBody(first), try transcriptBody(second))
        try append(message("Continue on the first account."), to: first)
        XCTAssertEqual(try prepare(sourceAccountID: firstAccount).transfer(to: secondAccount) { _, _, _ in
            XCTFail("The second account already has a native copy")
        }.transferredCount, 1)
        XCTAssertEqual(try transcriptBody(first), try transcriptBody(second))
        XCTAssertEqual(try header(first)["organizationId"] as? String, "first-org")
        XCTAssertEqual(try header(second)["organizationId"] as? String, "second-org")
        XCTAssertEqual(try Data(contentsOf: original), originalData)
    }

    func testDivergedBranchesAreNotOverwritten() throws {
        let original = try session(body: message("Common history."))
        let account = UUID()
        var target: URL!
        _ = try prepare().transfer(to: account) { id, _, _ in
            target = try self.session(id: id, organization: "target-org", folder: "native", body: Data())
        }
        try append(message("Source branch."), to: original)
        try append(message("Target branch."), to: target)
        let originalData = try Data(contentsOf: original), targetData = try Data(contentsOf: target)
        let plan = try prepare()
        XCTAssertEqual(plan.count, 0)
        let report = try plan.transfer(to: account) { _, _, _ in XCTFail("Diverged history must be skipped") }
        XCTAssertEqual(report.transferredCount, 0)
        XCTAssertTrue(report.warnings.contains { $0.contains("different history") })
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        XCTAssertEqual(try Data(contentsOf: target), targetData)
    }

    func testChangedSnapshotSkipsBeforeCreatingNativeSession() throws {
        let original = try session(body: message("Before the switch."))
        let plan = try prepare()
        try append(message("A writer changed the source."), to: original)
        let report = try plan.transfer(to: UUID()) { _, _, _ in XCTFail("The source snapshot changed") }
        XCTAssertEqual(report.transferredCount, 0)
        XCTAssertTrue(report.warnings.contains { $0.contains("changed during the switch") })
        XCTAssertFalse(fm.fileExists(atPath: state.path))
    }

    func testWriterGuardAndFinalDigestCheckPreserveLateTargetMessage() throws {
        _ = try session(body: message("Original request."))
        var target: URL!
        let lateMessage = try message("A process opened the destination.")
        let report = try prepare().transfer(to: UUID(), initialize: { id, _, _ in
            target = try self.session(id: id, organization: "target-org", folder: "native", body: Data())
        }, beforeWrite: {
            try self.append(lateMessage, to: target)
        })
        XCTAssertEqual(report.transferredCount, 0)
        XCTAssertEqual(try transcriptBody(target), lateMessage)
        XCTAssertTrue(report.warnings.contains { $0.contains("changed during the switch") })
    }

    func testFailedInitializerReservesIDAndAdoptsCreatedSessionOnRetry() throws {
        let original = try session(body: message("Preserve this request."))
        let originalData = try Data(contentsOf: original)
        let account = UUID()
        var reserved: UUID!
        let failed = try prepare().transfer(to: account) { id, _, _ in
            reserved = id
            _ = try self.session(id: id, organization: "target-org", folder: "native", body: Data())
            throw Interrupted.fault
        }
        XCTAssertEqual(failed.transferredCount, 0)
        XCTAssertEqual(failed.warnings.count, 1)
        let recovered = try prepare().transfer(to: account) { _, _, _ in XCTFail("The reserved native session exists") }
        XCTAssertEqual(recovered, .init(transferredCount: 1))
        XCTAssertEqual(try transcriptBody(path(reserved, folder: "native")), try transcriptBody(original))
        XCTAssertEqual(try Data(contentsOf: original), originalData)
    }

    func testFailedInitializerWithoutFileRetriesSameReservedID() throws {
        _ = try session(body: message("A complete conversation."))
        let account = UUID()
        var reserved: UUID!
        _ = try prepare().transfer(to: account) { id, _, _ in reserved = id; throw Interrupted.fault }
        let recovered = try prepare().transfer(to: account) { id, _, _ in
            XCTAssertEqual(id, reserved)
            _ = try self.session(id: id, organization: "target-org", folder: "native", body: Data())
        }
        XCTAssertEqual(recovered, .init(transferredCount: 1))
    }

    func testMissionsChildrenAndInvalidRecordsAreSkippedButOrdinaryTagsTransfer() throws {
        _ = try session(body: message("Ordinary conversation."))
        _ = try session(body: message("Ordinary custom-tag conversation."),
            extra: ["tags": [["name": "code-review", "metadata": ["topic": "parser"]]]])
        _ = try session(body: message("Ordinary string-tag conversation."), extra: ["tags": "code-review"])
        _ = try session(body: message("Child."), extra: ["callingSessionId": UUID().uuidString])
        _ = try session(body: message("Decomposition."), extra: ["decompMissionId": UUID().uuidString])
        _ = try session(body: message("Mission session type."), extra: ["decompSessionType": "orchestrator"])
        _ = try session(body: message("Tagged mission."), extra: ["tags": ["mission"]])
        _ = try session(body: message("Native mission tag."), extra: ["tags": [["name": "mission-session"]]])
        for key in ["missionId", "decompMissionId", "callingSessionId"] {
            _ = try session(body: message("Mission identity metadata."),
                extra: ["tags": [["name": "custom-tag", "metadata": [key: UUID().uuidString]]]])
        }
        let mission = UUID()
        _ = try session(id: mission, body: message("Mission folder."))
        try fm.createDirectory(at: home.appending(path: "missions/\(mission.uuidString.lowercased())"), withIntermediateDirectories: true)
        _ = try session(body: message("<system-reminder>Startup context only.</system-reminder>"))
        _ = try session(body: message("# AGENTS.md instructions for /synthetic/project"))
        _ = try session(body: Data("{\"type\":\"message\"".utf8))
        _ = try session(body: Data("invalid\n".utf8))
        let plan = try prepare()
        XCTAssertEqual(plan.count, 3)
        var copied: [URL] = []
        let report = try plan.transfer(to: UUID()) { id, _, _ in
            copied.append(try self.session(id: id, organization: "target-org", folder: "native", body: Data()))
        }
        XCTAssertEqual(copied.count, 3)
        XCTAssertEqual(report.transferredCount, 3)
        let bodies = try copied.map { String(decoding: try transcriptBody($0), as: UTF8.self) }
        XCTAssertTrue(bodies.contains { $0.contains("Ordinary custom-tag conversation.") })
        XCTAssertTrue(bodies.contains { $0.contains("Ordinary string-tag conversation.") })
        XCTAssertEqual(report.warnings.count, 2)
        XCTAssertFalse(report.warnings.joined().contains(root.path))
    }

    func testSelectsTenMostRecentAcrossProjects() throws {
        for index in 0..<12 {
            let file = try session(folder: "project-\(index)", body: message("Request \(index)."), extra: ["title": "Request \(index)"])
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: file.path)
        }
        var copied: [String] = []
        var creationOrder: [String] = []
        let report = try prepare().transfer(to: UUID()) { id, _, title in
            let target = try self.session(id: id, organization: "target-org", folder: "native", body: Data())
            copied.append(target.path)
            creationOrder.append(title)
        }
        XCTAssertEqual(report, .init(transferredCount: 10))
        let bodies = try copied.map { try String(decoding: self.transcriptBody(URL(fileURLWithPath: $0)), as: UTF8.self) }
        XCTAssertFalse(bodies.contains { $0.contains("Request 0.") || $0.contains("Request 1.") })
        XCTAssertTrue(bodies.contains { $0.contains("Request 11.") })
        XCTAssertEqual(creationOrder, (2..<12).map { "Request \($0)" })
    }

    func testTransferPreservesThreeConversationDatesAndNewestSelection() throws {
        let dates = (0..<3).map { Date(timeIntervalSince1970: Double(1_000 + $0)) }
        for index in 0..<3 {
            let original = try session(body: message("Conversation \(index)."), extra: ["title": "Conversation \(index)"])
            try fm.setAttributes([.modificationDate: dates[index]], ofItemAtPath: original.path)
        }
        let account = UUID()
        var created: [(title: String, url: URL)] = []
        let report = try prepare().transfer(to: account) { id, _, title in
            let target = try self.session(id: id, organization: "target-org", folder: "native", body: Data(), extra: ["title": title])
            created.append((title, target))
        }
        XCTAssertEqual(report, .init(transferredCount: 3))
        XCTAssertEqual(created.map { $0.title }, ["Conversation 0", "Conversation 1", "Conversation 2"])
        for (index, entry) in created.enumerated() {
            XCTAssertEqual(try entry.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, dates[index])
        }
        let repeated = try prepare().transfer(to: account) { _, _, _ in XCTFail("The native copies already exist") }
        XCTAssertEqual(repeated, .init(transferredCount: 0))
        let newest = try DroidConversationTransfer.prepare(home: home, state: state, sourceAccountID: nil, limit: 1)
        var selectedTitle: String?
        let returned = try newest.transfer(to: UUID()) { id, _, title in
            selectedTitle = title
            _ = try self.session(id: id, organization: "return-org", folder: "native", body: Data(), extra: ["title": title])
        }
        XCTAssertEqual(returned, .init(transferredCount: 1))
        XCTAssertEqual(selectedTitle, "Conversation 2")
    }

    func testSymlinkedSessionsAndDestinationAreNeverFollowed() throws {
        let outside = root.appending(path: "outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: "sessions"), withDestinationURL: outside)
        XCTAssertThrowsError(try prepare())
        try fm.removeItem(at: home.appending(path: "sessions"))
        _ = try session(body: message("Ordinary request."))
        let sentinel = outside.appending(path: "sentinel")
        let sentinelData = Data("Must not change.".utf8)
        try sentinelData.write(to: sentinel)
        let report = try prepare().transfer(to: UUID()) { id, _, _ in
            let destination = self.path(id, folder: "native")
            try self.fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try self.fm.createSymbolicLink(at: destination, withDestinationURL: sentinel)
        }
        XCTAssertEqual(report.transferredCount, 0)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
    }

    func testInvalidMappingAndMissingOrganizationFailClosed() throws {
        _ = try session(body: message("Ordinary request."))
        try fm.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: state)
        XCTAssertThrowsError(try prepare())
        try fm.removeItem(at: state)
        let report = try prepare().transfer(to: UUID()) { id, _, _ in
            _ = try self.session(id: id, organization: "", folder: "native", body: Data())
        }
        XCTAssertEqual(report.transferredCount, 0)
        XCTAssertEqual(report.warnings.count, 1)
    }

    func testDirectoryURLsWithTrailingSlashesComplete() throws {
        _ = try session(body: message("A normal request."))
        let directoryHome = URL(fileURLWithPath: home.path + "/", isDirectory: true)
        let plan = try DroidConversationTransfer.prepare(home: directoryHome, state: state, sourceAccountID: nil)
        XCTAssertEqual(plan.count, 1)
        let report = try plan.transfer(to: UUID()) { id, _, _ in
            _ = try self.session(id: id, organization: "target-org", folder: "native", body: Data())
        }
        XCTAssertEqual(report, .init(transferredCount: 1))
    }

    private func prepare(sourceAccountID: UUID? = nil) throws -> DroidConversationTransfer.Plan {
        try DroidConversationTransfer.prepare(home: home, state: state, sourceAccountID: sourceAccountID)
    }

    func testHeaderMustStartASession() throws {
        _ = try session(body: message("This is not a session header."), extra: ["type": "other"])
        let plan = try prepare()
        XCTAssertEqual(plan.count, 0)
        let report = try plan.transfer(to: UUID(), initialize: { _, _, _ in XCTFail("Invalid header was imported") })
        XCTAssertEqual(report.warnings.count, 1)
    }

    func testChangedNativeOrganizationDoesNotReceiveNewHistory() throws {
        let original = try session(body: message("Original history."))
        let account = UUID()
        var nativeID: UUID!
        _ = try prepare().transfer(to: account, initialize: { id, _, _ in
            nativeID = id
            _ = try self.session(id: id, organization: "target-org", folder: "native", body: Data())
        })
        let target = path(nativeID, folder: "native")
        let targetBody = try transcriptBody(target)
        _ = try session(id: nativeID, organization: "different-org", folder: "native", body: targetBody)
        let changedTarget = try Data(contentsOf: target)
        try append(message("New history must not go to the wrong organization."), to: original)
        let report = try prepare().transfer(to: account, initialize: { _, _, _ in XCTFail("A mapped session already exists") })
        XCTAssertEqual(report.transferredCount, 0)
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertEqual(try Data(contentsOf: target), changedTarget)
    }

    private func path(_ id: UUID, folder: String = "project") -> URL {
        home.appending(path: "sessions/\(folder)/\(id.uuidString.lowercased()).jsonl")
    }

    @discardableResult
    private func session(
        id: UUID = UUID(), organization: String = "source-org", folder: String = "project",
        body: Data, extra: [String: Any] = [:]
    ) throws -> URL {
        let url = path(id, folder: folder)
        var header: [String: Any] = ["type": "session_start", "id": id.uuidString.lowercased(),
            "organizationId": organization, "cwd": cwd.path, "title": "Synthetic conversation"]
        header.merge(extra) { _, value in value }
        let bytes = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]) + Data([10]) + body
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private func message(_ text: String, role: String = "user") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "message", "id": UUID().uuidString,
            "message": ["role": role, "content": [["type": "text", "text": text]]]], options: [.sortedKeys]) + Data([10])
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func transcriptBody(_ url: URL) throws -> Data {
        let bytes = try Data(contentsOf: url)
        let newline = try XCTUnwrap(bytes.firstIndex(of: 10))
        return Data(bytes.suffix(from: bytes.index(after: newline)))
    }

    private func header(_ url: URL) throws -> [String: Any] {
        let bytes = try Data(contentsOf: url)
        let newline = try XCTUnwrap(bytes.firstIndex(of: 10))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes.prefix(upTo: newline)) as? [String: Any])
    }
}
