import Foundation
import XCTest
@testable import AIManagerCore

final class DroidSessionBindingTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: URL!
    private var state: URL!

    override func setUpWithError() throws {
        let scratch = ProcessInfo.processInfo.environment["AGENT_DATA_DIR"]
            ?? ProcessInfo.processInfo.environment["TMPDIR"] ?? fm.temporaryDirectory.path
        root = URL(fileURLWithPath: scratch).appending(path: "switch/DroidSessionBindingTests-\(UUID().uuidString)")
        home = root.appending(path: ".factory")
        state = root.appending(path: "state")
        try CoreSupport.privateDirectory(home.appending(path: "sessions"), fileManager: fm)
    }

    override func tearDownWithError() throws { if let root { try fm.removeItem(at: root) } }

    private func session(id: UUID = UUID(), organization: String = "source", body: Data = Data(), extra: [String: Any] = [:]) throws -> URL {
        let path = home.appending(path: "sessions/project/\(id.uuidString).jsonl")
        var header: [String: Any] = ["type": "session_start", "id": id.uuidString,
            "organizationId": organization, "owner": "synthetic-owner", "cwd": "/missing/synthetic/project"]
        header.merge(extra) { _, value in value }
        try CoreSupport.atomicWrite(JSONSerialization.data(withJSONObject: header) + Data([10]) + body, to: path, fileManager: fm)
        return path
    }

    private func bind(_ organization: String = "target", beforeWrite: () throws -> Void = {}) throws -> DroidSessionBindingReport {
        try DroidSessionBinding.rebind(home: home, state: state, initialize: { id, cwd, _ in
            XCTAssertEqual(cwd.pathComponents, self.home.pathComponents)
            _ = try self.session(id: id, organization: organization)
        }, beforeWrite: beforeWrite)
    }

    func testPreservesOriginalIDsBytesSettingsAndMetadataInBothDirections() throws {
        let body = Data("{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"original body\"}}\n".utf8)
        let path = try session(body: body)
        let before = try Data(contentsOf: path)
        let settings = path.deletingPathExtension().appendingPathExtension("settings.json")
        let settingsBytes = Data("{\"model\":\"keep-original-model\"}".utf8)
        try settingsBytes.write(to: settings)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.posixPermissions: 0o640, .modificationDate: modified], ofItemAtPath: path.path)
        #if os(macOS)
        let created = try fm.attributesOfItem(atPath: path.path)[.creationDate] as? Date
        #endif
        XCTAssertEqual(try bind(), .init(updatedCount: 1))
        XCTAssertEqual(try Data(contentsOf: path), Data(String(decoding: before, as: UTF8.self)
            .replacingOccurrences(of: "\"source\"", with: "\"target\"").utf8))
        XCTAssertEqual(try Data(contentsOf: settings), settingsBytes)
        XCTAssertEqual(try fm.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(try fm.attributesOfItem(atPath: path.path)[.modificationDate] as? Date, modified)
        #if os(macOS)
        XCTAssertEqual(try fm.attributesOfItem(atPath: path.path)[.creationDate] as? Date, created)
        #endif
        XCTAssertEqual(try bind(), .init(unchangedCount: 1))
        XCTAssertEqual(try bind("source"), .init(updatedCount: 1))
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: path.deletingLastPathComponent().path).filter { $0.hasSuffix(".jsonl") }.count, 1)
    }

    func testBindsEveryOrdinarySessionIncludingEmptyAndChildrenWithoutAProjectFolder() throws {
        let parent = UUID()
        _ = try session(id: parent)
        for _ in 0..<12 { _ = try session(extra: ["parentSessionId": parent.uuidString]) }
        XCTAssertEqual(try bind(), .init(updatedCount: 13))
    }

    func testRawHeaderWhitespaceEscapesAndNestedOrganizationStayExact() throws {
        let id = UUID()
        let path = home.appending(path: "sessions/\(id.uuidString).jsonl")
        let raw = " { \"type\" : \"session_start\", \"id\":\"\(id.uuidString)\", \"nested\":{\"organizationId\":\"keep\"}, \"organizationId\" : \"sour\\u0063e\" }\r\n{not parsed body}\n"
        try Data(raw.utf8).write(to: path)
        XCTAssertEqual(try bind("target\"escaped"), .init(updatedCount: 1))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), raw.replacingOccurrences(of: "\"sour\\u0063e\"", with: "\"target\\\"escaped\""))
    }

    func testMissionHeadersAndAllTheirDescendantsStayOwnedByTheOriginalAccount() throws {
        let mission = UUID(), child = UUID(), grandchild = UUID()
        let original = try session(id: mission, extra: ["missionId": "synthetic-mission"])
        let first = try session(id: child, extra: ["parentSessionId": mission.uuidString])
        let second = try session(id: grandchild, extra: ["callingSessionId": child.uuidString])
        let originalBytes = try [original, first, second].map { try Data(contentsOf: $0) }
        _ = try session()
        let result = try bind()
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(result.skippedCount, 3)
        XCTAssertEqual(try [original, first, second].map { try Data(contentsOf: $0) }, originalBytes)
    }

    func testDuplicateOrganizationKeysInvalidHeadersAndLinksArePreserved() throws {
        let id = UUID()
        let malformed = home.appending(path: "sessions/\(id.uuidString).jsonl")
        let raw = "{\"type\":\"session_start\",\"id\":\"\(id.uuidString)\",\"organizationId\":\"source\",\"organizationId\":\"other\"}\n"
        try Data(raw.utf8).write(to: malformed)
        let ordinary = try session()
        let linked = home.appending(path: "sessions/\(UUID().uuidString).jsonl")
        try fm.createSymbolicLink(at: linked, withDestinationURL: ordinary)
        let report = try bind()
        XCTAssertEqual(report.updatedCount, 1, report.warnings.joined(separator: "\n"))
        XCTAssertEqual(report.skippedCount, 2)
        XCTAssertEqual(try String(contentsOf: malformed, encoding: .utf8), raw)
        XCTAssertTrue(try linked.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testWriterRacePreservesAppendedBodyAndRetryUsesTheSameSession() throws {
        let path = try session()
        let before = try Data(contentsOf: path)
        let append = Data("{\"type\":\"new-record\"}\n".utf8)
        var checks = 0
        let result = try bind(beforeWrite: {
            checks += 1
            if checks == 2 {
                let handle = try FileHandle(forWritingTo: path)
                try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.close()
            }
        })
        XCTAssertEqual(result.updatedCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(try Data(contentsOf: path), before + append)
        XCTAssertEqual(try bind().updatedCount, 1)
        XCTAssertEqual(try Data(contentsOf: path), Data(String(decoding: before, as: UTF8.self)
            .replacingOccurrences(of: "\"source\"", with: "\"target\"").utf8) + append)
        XCTAssertFalse(fm.fileExists(atPath: state.appending(path: "pending.json").path))
    }

    func testFailedProbePreservesAllOriginalSessionsAndRemovesOnlyItsOwnEmptyFiles() throws {
        let path = try session()
        let before = try Data(contentsOf: path)
        enum ProbeFailure: Error { case failed }
        XCTAssertThrowsError(try DroidSessionBinding.rebind(home: home, state: state, initialize: { id, _, _ in
            let probe = try self.session(id: id, organization: "target")
            try Data("{}".utf8).write(to: probe.deletingPathExtension().appendingPathExtension("settings.json"))
            throw ProbeFailure.failed
        }))
        XCTAssertEqual(try Data(contentsOf: path), before)
        let files = try fm.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
        XCTAssertEqual(files, [path.lastPathComponent])
        XCTAssertEqual(try bind().updatedCount, 1)
    }

    func testStreamingBodyHasNoThirtyTwoMegabyteCeiling() throws {
        let path = try session()
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        let chunk = Data(repeating: 65, count: 1_048_576)
        for _ in 0..<33 { try handle.write(contentsOf: chunk) }
        try handle.close()
        let size = try fm.attributesOfItem(atPath: path.path)[.size] as? Int
        XCTAssertEqual(try bind().updatedCount, 1)
        XCTAssertEqual(try fm.attributesOfItem(atPath: path.path)[.size] as? Int, size)
        let reader = try FileHandle(forReadingFrom: path)
        try reader.seek(toOffset: UInt64((size ?? 0) - chunk.count))
        XCTAssertEqual(try reader.read(upToCount: chunk.count), chunk)
        try reader.close()
    }

    func testInterruptedPublishedUpdateIsAdoptedWithoutChangingTheBody() throws {
        let path = try session()
        let original = try Data(contentsOf: path)
        let updated = Data(String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "\"source\"", with: "\"target\"").utf8)
        try updated.write(to: path)
        let temporaryName = ".switch-bind-\(UUID().uuidString).tmp"
        let temporary = path.deletingLastPathComponent().appending(path: temporaryName)
        try original.write(to: temporary)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let journal: [String: Any] = [
            "path": "project/\(path.lastPathComponent)", "temporary": temporaryName,
            "originalHeader": original.base64EncodedString(), "newHeader": updated.base64EncodedString(),
            "originalDigest": CoreSupport.digest(original), "updatedDigest": CoreSupport.digest(updated),
            "modified": modified.timeIntervalSinceReferenceDate, "permissions": 0o640,
        ]
        try CoreSupport.privateDirectory(state, fileManager: fm)
        try JSONSerialization.data(withJSONObject: journal).write(to: state.appending(path: "pending.json"))
        XCTAssertEqual(try bind(), .init(unchangedCount: 1))
        XCTAssertEqual(try Data(contentsOf: path), updated)
        XCTAssertEqual(try fm.attributesOfItem(atPath: path.path)[.modificationDate] as? Date, modified)
        XCTAssertFalse(fm.fileExists(atPath: temporary.path))
        XCTAssertFalse(fm.fileExists(atPath: state.appending(path: "pending.json").path))
    }

    func testInterruptedExchangeRestoresAnAppendedOriginalBeforeRetrying() throws {
        let path = try session(body: Data("{\"type\":\"original-record\"}\n".utf8))
        let original = try Data(contentsOf: path)
        let updated = Data(String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "\"source\"", with: "\"target\"").utf8)
        let append = Data("{\"type\":\"late-original-record\"}\n".utf8)
        try updated.write(to: path)
        let temporary = try pendingExchange(path, original: original, updated: updated, displaced: original + append)
        XCTAssertEqual(try bind().updatedCount, 1)
        XCTAssertEqual(try Data(contentsOf: path), updated + append)
        XCTAssertFalse(fm.fileExists(atPath: temporary.path))
        XCTAssertFalse(fm.fileExists(atPath: state.appending(path: "pending.json").path))
    }

    func testInterruptedExchangeWithBothSidesChangedPreservesBothAndItsJournal() throws {
        let path = try session(body: Data("{\"type\":\"original-record\"}\n".utf8))
        let original = try Data(contentsOf: path)
        let updated = Data(String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "\"source\"", with: "\"target\"").utf8)
        let originalAppend = Data("{\"type\":\"old-inode-write\"}\n".utf8)
        let targetAppend = Data("{\"type\":\"new-inode-write\"}\n".utf8)
        try (updated + targetAppend).write(to: path)
        let temporary = try pendingExchange(path, original: original, updated: updated, displaced: original + originalAppend)
        XCTAssertThrowsError(try bind()) { error in
            XCTAssertTrue(error.localizedDescription.contains("conflicting edits"))
        }
        XCTAssertEqual(try Data(contentsOf: path), updated + targetAppend)
        XCTAssertEqual(try Data(contentsOf: temporary), original + originalAppend)
        XCTAssertTrue(fm.fileExists(atPath: state.appending(path: "pending.json").path))
    }

    func testWriterStartingAfterExchangeKeepsBothInodesAndTheRecoveryJournal() throws {
        let path = try session()
        let original = try Data(contentsOf: path)
        enum WriterStarted: Error { case active }
        var checks = 0
        XCTAssertThrowsError(try bind(beforeWrite: {
            checks += 1
            if checks >= 3 { throw WriterStarted.active }
        }))
        XCTAssertEqual(try Data(contentsOf: path), Data(String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "\"source\"", with: "\"target\"").utf8))
        let temporary = try XCTUnwrap(fm.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".switch-bind-") })
        XCTAssertEqual(try Data(contentsOf: temporary), original)
        XCTAssertTrue(fm.fileExists(atPath: state.appending(path: "pending.json").path))
    }

    func testProbeCleanupKeepsItsFileWhenAWriterStarts() throws {
        _ = try session()
        enum WriterStarted: Error { case active }
        var checks = 0
        let report = try bind(beforeWrite: {
            checks += 1
            if checks >= 5 { throw WriterStarted.active }
        })
        XCTAssertEqual(report.updatedCount, 1)
        XCTAssertTrue(report.warnings.contains { $0.contains("native check session was preserved") })
        let files = try fm.contentsOfDirectory(atPath: home.appending(path: "sessions/project").path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".jsonl") }.count, 2)
    }

    func testProbeDirectoryCleanupDoesNotRemoveAConcurrentlyCreatedSession() throws {
        _ = try session()
        let probeDirectory = home.appending(path: "sessions/new-probe-directory")
        let survivor = probeDirectory.appending(path: "\(UUID().uuidString).jsonl")
        let survivorBytes = Data("concurrent session must survive".utf8)
        var probePath: URL?
        let report = try DroidSessionBinding.rebind(home: home, state: state, initialize: { id, _, _ in
            let path = probeDirectory.appending(path: "\(id.uuidString).jsonl")
            let header: [String: Any] = ["type": "session_start", "id": id.uuidString, "organizationId": "target"]
            try CoreSupport.atomicWrite(JSONSerialization.data(withJSONObject: header) + Data([10]), to: path, fileManager: self.fm)
            probePath = path
        }, beforeWrite: {
            if let probePath, !self.fm.fileExists(atPath: probePath.path), !self.fm.fileExists(atPath: survivor.path) {
                try survivorBytes.write(to: survivor)
            }
        })
        XCTAssertEqual(report.updatedCount, 1)
        XCTAssertEqual(try Data(contentsOf: survivor), survivorBytes)
    }

    func testOrganizationReplacementCannotExceedTheHeaderLimitOrLeaveAJournal() throws {
        let id = UUID()
        let path = try session(id: id, extra: ["padding": ""])
        let baseSize = try Data(contentsOf: path).count
        _ = try session(id: id, extra: ["padding": String(repeating: "p", count: 1_048_576 - baseSize - 8)])
        let original = try Data(contentsOf: path)
        XCTAssertEqual(original.count, 1_048_576 - 8)
        let report = try bind(String(repeating: "t", count: 300))
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertTrue(report.warnings.contains { $0.contains("header too large") })
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertFalse(fm.fileExists(atPath: state.appending(path: "pending.json").path))
        let files = try fm.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".switch-bind-") })
    }

    private func pendingExchange(_ path: URL, original: Data, updated: Data, displaced: Data) throws -> URL {
        let name = ".switch-bind-\(UUID().uuidString).tmp"
        let temporary = path.deletingLastPathComponent().appending(path: name)
        try displaced.write(to: temporary)
        let originalEnd = try XCTUnwrap(original.firstIndex(of: 10))
        let updatedEnd = try XCTUnwrap(updated.firstIndex(of: 10))
        let journal: [String: Any] = [
            "path": "project/\(path.lastPathComponent)", "temporary": name,
            "originalHeader": original.prefix(through: originalEnd).base64EncodedString(),
            "newHeader": updated.prefix(through: updatedEnd).base64EncodedString(),
            "originalDigest": CoreSupport.digest(original), "updatedDigest": CoreSupport.digest(updated),
            "modified": Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate,
            "permissions": 0o600,
        ]
        try CoreSupport.privateDirectory(state, fileManager: fm)
        try JSONSerialization.data(withJSONObject: journal).write(to: state.appending(path: "pending.json"))
        return temporary
    }
}
