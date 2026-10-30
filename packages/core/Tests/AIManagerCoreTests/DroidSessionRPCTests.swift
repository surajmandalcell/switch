import Foundation
import XCTest
@testable import AIManagerCore

final class DroidSessionRPCTests: XCTestCase {
    func testInitializeRequestHasNoUserPrompt() throws {
        let sessionID = UUID()
        let machineID = UUID()
        let request = try DroidSessionRPC.makeInitializeRequest(
            requestID: "request-1",
            sessionID: sessionID,
            machineID: machineID,
            cwd: URL(fileURLWithPath: "/work/project"),
            title: "Imported conversation"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])

        XCTAssertEqual(object["method"] as? String, "droid.initialize_session")
        XCTAssertEqual(params["sessionId"] as? String, sessionID.uuidString.lowercased())
        XCTAssertEqual(params["machineId"] as? String, machineID.uuidString.lowercased())
        XCTAssertEqual(params["cwd"] as? String, "/work/project")
        XCTAssertEqual(params["title"] as? String, "Imported conversation")
        XCTAssertEqual(params["mcpServers"] as? [String], [])
        XCTAssertEqual(params["autonomyLevel"] as? String, "off")
        XCTAssertEqual(params["disableBuiltinSkills"] as? Bool, true)
        XCTAssertEqual(params["autoRejectPermissionRequests"] as? Bool, true)
        XCTAssertNil(params["text"])
        XCTAssertNil(params["messages"])
    }

    func testResponseMustMatchRequestAndCreatedSession() throws {
        let sessionID = UUID()
        let unrelated = try response(id: "other", sessionID: sessionID)
        XCTAssertFalse(try DroidSessionRPC.validateResponse(unrelated, requestID: "request-1", sessionID: sessionID))

        let matching = try response(id: "request-1", sessionID: sessionID)
        XCTAssertTrue(try DroidSessionRPC.validateResponse(matching, requestID: "request-1", sessionID: sessionID))

        let wrongSession = try response(id: "request-1", sessionID: UUID())
        XCTAssertThrowsError(try DroidSessionRPC.validateResponse(wrongSession, requestID: "request-1", sessionID: sessionID)) {
            XCTAssertEqual($0 as? DroidSessionRPCError, .invalidResponse)
        }
    }

    func testRPCErrorDoesNotExposeServerText() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "request-1",
            "error": ["code": -32004, "message": "private server detail"],
        ])

        XCTAssertThrowsError(try DroidSessionRPC.validateResponse(data, requestID: "request-1", sessionID: UUID())) {
            XCTAssertEqual($0 as? DroidSessionRPCError, .requestRejected)
            XCTAssertEqual(($0 as? DroidSessionRPCError)?.errorDescription, "Factory Droid rejected the session request.")
        }
    }

    func testInitializeReadsShortResponseAndStopsProcess() throws {
        let scratch = ProcessInfo.processInfo.environment["AGENT_DATA_DIR"]
            ?? ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
        let root = URL(fileURLWithPath: scratch).appending(path: "switch/DroidSessionRPCTests-\(UUID())")
        let home = root.appending(path: "home/.factory")
        let cwd = root.appending(path: "project")
        let settings = root.appending(path: "settings.json")
        let executable = root.appending(path: "fake-droid")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: settings)
        let script = #"""
        #!/bin/sh
        IFS= read -r request || exit 3
        request_id=$(printf '%s\n' "$request" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\1/')
        session_id=$(printf '%s\n' "$request" | /usr/bin/sed -E 's/.*"sessionId":"([^"]+)".*/\1/')
        printf '{"type":"response","jsonrpc":"2.0","id":"%s","result":{"sessionId":"%s"}}\n' "$request_id" "$session_id"
        IFS= read -r ignored
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let started = Date()
        try DroidSessionRPC.initialize(
            executable: executable,
            home: home,
            sessionID: UUID(),
            cwd: cwd,
            title: "Synthetic conversation",
            settingsFile: settings
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    private func response(id: String, sessionID: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "response",
            "jsonrpc": "2.0",
            "id": id,
            "result": ["sessionId": sessionID.uuidString.lowercased()],
        ])
    }
}
