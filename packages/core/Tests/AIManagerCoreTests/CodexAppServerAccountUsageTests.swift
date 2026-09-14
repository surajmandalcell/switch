import Foundation
import XCTest
@testable import AIManagerCore

final class CodexAppServerAccountUsageTests: XCTestCase {
    private var root: URL!
    private var source: CodexAppServerSource!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(
            path: "CodexAppServerAccountUsageTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let home = root.appending(path: "isolated-codex-home", directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let authFile = home.appending(path: "auth.json")
        try Data(#"{"synthetic":true}"#.utf8).write(to: authFile)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
        source = CodexAppServerSource(codexHome: home, authFile: authFile)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    func testReaderDecodesAccountRateLimitsAndUsageWithoutSecrets() async throws {
        let transport = SyntheticAccountTransport(records: [
            response(id: 4, result: [
                "summary": [
                    "lifetimeTokens": 123_456,
                    "peakDailyTokens": 9_000,
                    "currentStreakDays": 4,
                    "longestStreakDays": 8,
                    "longestRunningTurnSec": 77,
                ],
                "dailyUsageBuckets": [
                    ["startDate": "2026-09-13", "tokens": 3_200],
                ],
            ]),
            response(id: 2, result: [
                "account": [
                    "type": "chatgpt",
                    "email": "person@example.test",
                    "planType": "plus",
                ],
                "requiresOpenaiAuth": true,
            ]),
            response(id: 3, result: [
                "accountId": "account-synthetic",
                "ordinaryUsageAllowed": true,
                "rateLimits": [
                    "limitId": "codex",
                    "limitName": "Codex",
                    "planType": "plus",
                    "normalModelSlug": "gpt-5",
                    "primary": [
                        "usedPercent": 26,
                        "windowDurationMins": 300,
                        "resetsAt": 1_789_000_000,
                    ],
                    "secondary": ["usedPercent": 44],
                    "credits": ["hasCredits": true, "unlimited": false, "balance": "12.50"],
                    "spendControlReached": false,
                ],
                "rateLimitsByLimitId": [
                    "codex": [
                        "limitId": "codex",
                        "primary": ["usedPercent": 26],
                    ],
                ],
            ]),
        ])
        let instant = Date(timeIntervalSince1970: 1_789_000_100)
        let reader = CodexAppServerAccountReader(
            transport: transport,
            environment: {
                [
                    "PATH": "/usr/bin",
                    "OPENAI_API_KEY": "must-not-leak",
                    "CODEX_ACCESS_TOKEN": "must-not-leak",
                    "ANTHROPIC_API_KEY": "must-not-leak",
                    "GH_TOKEN": "must-not-leak",
                    "SAFE_SETTING": "kept",
                ]
            },
            now: { instant }
        )

        let snapshot = try await reader.read(
            executable: URL(fileURLWithPath: "/synthetic/codex"),
            source: source
        )

        XCTAssertEqual(snapshot.account?.kind, "chatgpt")
        XCTAssertEqual(snapshot.account?.email, "person@example.test")
        XCTAssertEqual(snapshot.account?.plan, "plus")
        XCTAssertEqual(snapshot.requiresOpenAIAuthentication, true)
        XCTAssertEqual(snapshot.rateLimits?.accountID, "account-synthetic")
        XCTAssertEqual(snapshot.rateLimits?.ordinaryUsageAllowed, true)
        XCTAssertEqual(snapshot.rateLimits?.defaultBucket?.primary?.usedPercent, 26)
        XCTAssertEqual(snapshot.rateLimits?.defaultBucket?.secondary?.usedPercent, 44)
        XCTAssertEqual(snapshot.rateLimits?.buckets["codex"]?.primary?.usedPercent, 26)
        XCTAssertEqual(snapshot.usage?.lifetimeTokens, 123_456)
        XCTAssertEqual(snapshot.usage?.longestRunningTurnSeconds, 77)
        XCTAssertEqual(snapshot.dailyUsage, [.init(startDate: "2026-09-13", tokens: 3_200)])
        XCTAssertEqual(snapshot.fetchedAt, instant)

        let launch = try XCTUnwrap(transport.capturedLaunch)
        XCTAssertEqual(launch.arguments, ["app-server", "--stdio"])
        XCTAssertEqual(launch.environment["CODEX_HOME"], source.codexHome.path)
        XCTAssertEqual(launch.environment["SAFE_SETTING"], "kept")
        XCTAssertNil(launch.environment["OPENAI_API_KEY"])
        XCTAssertNil(launch.environment["CODEX_ACCESS_TOKEN"])
        XCTAssertNil(launch.environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(launch.environment["GH_TOKEN"])

        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("must-not-leak"))
        XCTAssertFalse(encoded.lowercased().contains("access_token"))
        XCTAssertFalse(encoded.lowercased().contains("refresh_token"))
    }

    func testReaderTreatsAbsentBackendFieldsAsUnavailable() async throws {
        let transport = SyntheticAccountTransport(records: [
            response(id: 2, result: ["requiresOpenaiAuth": false]),
            response(id: 3, result: [:]),
            response(id: 4, result: [:]),
        ])

        let snapshot = try await CodexAppServerAccountReader(
            transport: transport,
            environment: { [:] }
        ).read(executable: URL(fileURLWithPath: "/synthetic/codex"), source: source)

        XCTAssertNil(snapshot.account)
        XCTAssertEqual(snapshot.requiresOpenAIAuthentication, false)
        XCTAssertNil(snapshot.rateLimits?.accountID)
        XCTAssertNil(snapshot.rateLimits?.ordinaryUsageAllowed)
        XCTAssertNil(snapshot.rateLimits?.defaultBucket)
        XCTAssertEqual(snapshot.rateLimits?.buckets, [:])
        XCTAssertNil(snapshot.usage)
        XCTAssertEqual(snapshot.dailyUsage, [])
    }

    func testReaderKeepsAccountAndLimitsWhenUsageEndpointIsUnavailable() async throws {
        let transport = SyntheticAccountTransport(records: [
            response(id: 2, result: [
                "account": ["type": "chatgpt", "email": "person@example.test"],
                "requiresOpenaiAuth": true,
            ]),
            response(id: 3, result: [
                "rateLimits": ["primary": ["usedPercent": 37]],
            ]),
            rpcError(id: 4, code: -32601, message: "Method not found"),
        ])

        let snapshot = try await CodexAppServerAccountReader(
            transport: transport,
            environment: { [:] }
        ).read(executable: URL(fileURLWithPath: "/synthetic/codex"), source: source)

        XCTAssertEqual(snapshot.account?.email, "person@example.test")
        XCTAssertEqual(snapshot.rateLimits?.defaultBucket?.primary?.usedPercent, 37)
        XCTAssertNil(snapshot.usage)
        XCTAssertEqual(snapshot.dailyUsage, [])
    }

    func testReaderRejectsAuthOutsideTheIsolatedHomeAndNonPrivateAuth() async throws {
        let transport = SyntheticAccountTransport(records: [])
        let reader = CodexAppServerAccountReader(transport: transport, environment: { [:] })
        let outside = CodexAppServerSource(
            codexHome: source.codexHome,
            authFile: root.appending(path: "other-auth.json")
        )

        await XCTAssertThrowsErrorAsync(
            try await reader.read(executable: URL(fileURLWithPath: "/synthetic/codex"), source: outside)
        ) { error in
            XCTAssertEqual(
                error as? CodexAppServerError,
                .invalidSource("The auth source must be CODEX_HOME/auth.json.")
            )
        }

        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.authFile.path)
        await XCTAssertThrowsErrorAsync(
            try await reader.read(executable: URL(fileURLWithPath: "/synthetic/codex"), source: source)
        ) { error in
            XCTAssertEqual(
                error as? CodexAppServerError,
                .invalidSource("The auth source must be a private regular file with one link.")
            )
        }
        XCTAssertNil(transport.capturedLaunch)
    }

    func testProcessTransportUsesInitializedJSONLAndOnlyAccountReadMethods() async throws {
        let transcript = root.appending(path: "requests.jsonl")
        let executable = try syntheticServer(
            """
            IFS= read -r line
            printf '%s\\n' "$line" >> "$SWITCH_TEST_TRANSCRIPT"
            printf '{"id":1,"result":{"codexHome":"synthetic","platformFamily":"unix","platformOs":"test","userAgent":"test"}}\\n'
            IFS= read -r line
            printf '%s\\n' "$line" >> "$SWITCH_TEST_TRANSCRIPT"
            IFS= read -r line
            printf '%s\\n' "$line" >> "$SWITCH_TEST_TRANSCRIPT"
            IFS= read -r line
            printf '%s\\n' "$line" >> "$SWITCH_TEST_TRANSCRIPT"
            IFS= read -r line
            printf '%s\\n' "$line" >> "$SWITCH_TEST_TRANSCRIPT"
            printf '{"id":4,"result":{"summary":{}}}\\n'
            printf '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}\\n'
            printf '{"id":3,"result":{"rateLimits":{}}}\\n'
            """
        )
        let reader = CodexAppServerAccountReader(
            environment: {
                [
                    "PATH": "/usr/bin:/bin",
                    "SWITCH_TEST_TRANSCRIPT": transcript.path,
                    "OPENAI_API_KEY": "must-not-leak",
                ]
            }
        )

        _ = try await reader.read(
            executable: executable,
            source: source,
            limits: .init(timeout: 2, maximumOutputBytes: 32_768, maximumLineBytes: 8_192)
        )

        let lines = String(decoding: try Data(contentsOf: transcript), as: UTF8.self)
            .split(separator: "\n")
            .map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0]["method"] as? String, "initialize")
        XCTAssertEqual(lines[1]["method"] as? String, "initialized")
        XCTAssertEqual(lines[2]["method"] as? String, "account/read")
        XCTAssertEqual(lines[3]["method"] as? String, "account/rateLimits/read")
        XCTAssertEqual(lines[4]["method"] as? String, "account/usage/read")
        XCTAssertFalse(lines.contains { ($0["method"] as? String)?.contains("turn/") == true })
        XCTAssertFalse(lines.contains { ($0["method"] as? String)?.contains("model") == true })
    }

    func testProcessTransportEnforcesTimeoutAndOutputBounds() async throws {
        let slow = try syntheticServer("exec sleep 2")
        await XCTAssertThrowsErrorAsync(
            try await CodexAppServerAccountReader(environment: { ["PATH": "/usr/bin:/bin"] }).read(
                executable: slow,
                source: source,
                limits: .init(timeout: 0.1, maximumOutputBytes: 1_024, maximumLineBytes: 512)
            )
        ) { error in
            XCTAssertEqual(error as? CodexAppServerError, .timedOut)
        }

        let noisy = try syntheticServer(
            """
            IFS= read -r line
            printf '{"id":1,"result":{"padding":"'
            head -c 2048 /dev/zero | tr '\\000' x
            printf '"}}\\n'
            """
        )
        await XCTAssertThrowsErrorAsync(
            try await CodexAppServerAccountReader(environment: { ["PATH": "/usr/bin:/bin"] }).read(
                executable: noisy,
                source: source,
                limits: .init(timeout: 1, maximumOutputBytes: 512, maximumLineBytes: 512)
            )
        ) { error in
            XCTAssertEqual(error as? CodexAppServerError, .outputLimitExceeded)
        }
    }

    func testCancellingReadTerminatesTheChildPromptly() async throws {
        let slow = try syntheticServer("exec sleep 10")
        let reader = CodexAppServerAccountReader(environment: { ["PATH": "/usr/bin:/bin"] })
        let started = Date()
        let task = Task {
            try await reader.read(
                executable: slow,
                source: source,
                limits: .init(timeout: 5, maximumOutputBytes: 1_024, maximumLineBytes: 512)
            )
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? CodexAppServerError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    private func response(id: Int, result: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["id": id, "result": result], options: [.sortedKeys])
    }

    private func rpcError(id: Int, code: Int, message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "id": id,
            "error": ["code": code, "message": message],
        ], options: [.sortedKeys])
    }

    private func syntheticServer(_ body: String) throws -> URL {
        let executable = root.appending(path: "synthetic-codex-\(UUID().uuidString).sh")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}

private final class SyntheticAccountTransport: CodexAppServerRPCTransport, @unchecked Sendable {
    private let records: [Data]
    private let lock = NSLock()
    private var launch: CodexAppServerLaunch?

    init(records: [Data]) {
        self.records = records
    }

    var capturedLaunch: CodexAppServerLaunch? {
        lock.withLock { launch }
    }

    func performAccountRead(
        launch: CodexAppServerLaunch,
        limits: CodexAppServerLimits
    ) async throws -> [Data] {
        lock.withLock { self.launch = launch }
        return records
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        handler(error)
    }
}
