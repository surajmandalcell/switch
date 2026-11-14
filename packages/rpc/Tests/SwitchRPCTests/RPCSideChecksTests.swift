import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel
@testable import SwitchRPC

/// Recovery, caches, side checks, missions, detection, and quota notifications over the protocol.
extension RPCRuntimeTests {
    func testRecoveryCachesAndSideChecks() async throws {
        let manager = try manager()
        let account = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let id = account.id.uuidString.lowercased()
        let session = try session(manager: manager)

        let recovered = try await call(session, 1, "recovery.recover", "{}")
        XCTAssertEqual(result(recovered)?["status"] as? String, "done")
        XCTAssertEqual(result(recovered)?["notice"] as? String, "No backup work was needed.")
        let badID = try await call(session, 2, "recovery.resolve", #"{"operationID":"nope","choice":"preserveCurrent"}"#)
        XCTAssertEqual(errorCode(badID), -32602)
        let unknown = try await call(session, 3, "recovery.resolve",
                                     #"{"operationID":"\#(UUID().uuidString)","choice":"preserveCurrent"}"#)
        XCTAssertNotNil(errorCode(unknown) ?? (result(unknown)?["status"] as? String == "failed" ? 0 : nil))
        let repair = try await call(session, 4, "accounts.repairLink",
                                    #"{"accountID":"\#(id)","relativePath":"config.toml","fingerprint":"x"}"#)
        XCTAssertNotEqual(result(repair)?["status"] as? String, "done")

        let sizesReply = try await call(session, 5, "usage.cacheSizes", "{}")
        let sizes = try XCTUnwrap(result(sizesReply))
        XCTAssertNotNil(sizes["usageBytes"] as? Int)
        XCTAssertNotNil(sizes["conversationBytes"] as? Int)
        for (number, method) in [(6, "usage.clearCache"), (7, "history.reindex"), (8, "history.clearIndex")] {
            let reply = try await call(session, number, method, "{}")
            XCTAssertEqual(result(reply)?["status"] as? String, "done", method)
        }

        // A test home makes no request: the status and activity answers are empty.
        let statusReply = try await call(session, 9, "providerStatus.refresh", "{}")
        let status = try XCTUnwrap(result(statusReply))
        XCTAssertEqual((status["entries"] as? [Any])?.count, 0)
        let activityReply = try await call(session, 10, "activity.refresh", #"{"force":true}"#)
        let activity = try XCTUnwrap(result(activityReply))
        XCTAssertEqual(activity["claudeLoading"] as? Bool, false)
        let binding = try await call(session, 11, "droid.refreshConversations", "{}")
        XCTAssertNotNil(result(binding))

        for (number, method) in [(12, "droid.setMissionOwner"), (13, "droid.resumeMission"), (14, "droid.startMissionHere")] {
            let reply = try await call(session, number, method, #"{"missionID":"no-such-mission","accountID":"\#(id)"}"#)
            XCTAssertNotNil(errorCode(reply) ?? (result(reply)?["status"] as? String == "failed" ? 0 : nil), method)
        }
        let permission = try await call(session, 15, "notifications.setPermission", #"{"status":"maybe"}"#)
        XCTAssertEqual(errorCode(permission), -32602)
        try await session.close()
        XCTAssertFalse(session.raw.contains(canary))
    }

    /// Detection reads the root's home only: a planted Codebuff login is found, its token never leaves.
    func testDetectSignedInReadsTheRootHome() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let file = paths.userHome.appending(path: ".config/manicode/credentials.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"default":{"id":"u-1","email":"a@x.test","authToken":"\#(canary)"}}"#.utf8).write(to: file)
        let session = try session(manager: manager)
        let reply = try await call(session, 1, "providers.detectSignedIn", "{}")
        XCTAssertEqual(result(reply)?["signedIn"] as? [String], ["codebuff"])
        try await session.close()
        XCTAssertFalse(session.raw.contains(canary))
    }

    /// A quota alert becomes `notify.post` when the client said it can notify, and stops once it says denied.
    func testQuotaAlertPostsANotification() async throws {
        final class Box: @unchecked Sendable { var used = 50.0 }
        let box = Box()
        let spec = ProviderSpec(id: provider.rawValue, name: "RPC Test", style: .secret, fields: [.apiKey("TEST_RPC_KEY")],
                                fetch: { _ in FetchResult(ProviderUsage(windows: [UsageWindow(id: "balance", title: "Credits",
                                                                                              usedPercent: box.used)])) })
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: [spec])
        _ = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let server = RPCServer(manager: manager, paths: paths, version: "test-version", log: { _ in })
        await server.engine.setRefreshesInIsolation(true)
        await server.engine.setStatusPoller(ProviderStatusPoller(fetch: { _, _ in nil }))
        let session = Session(server)
        func posts() -> [[String: Any]] {
            session.frames.filter { $0["method"] as? String == "notify.post" }.compactMap { $0["params"] as? [String: Any] }
        }
        _ = try await call(session, 1, "initialize", #"{"locale":"en_GB","hourCycle":"h23","capabilities":{"notifications":true}}"#)
        _ = try await call(session, 2, "settings.set", #"{"key":"notifyAlmostOut","value":true}"#)
        _ = try await call(session, 3, "app.refresh", "{}")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(posts().isEmpty, "the first pass only primes")
        box.used = 95
        _ = try await call(session, 4, "app.refresh", "{}")
        try await session.wait { _ in !posts().isEmpty }
        XCTAssertEqual(posts().first?["title"] as? String, "Almost Out")
        XCTAssertEqual(posts().first?["group"] as? String, "switch.quota")

        _ = try await call(session, 5, "notifications.setPermission", #"{"status":"denied"}"#)
        box.used = 40
        _ = try await call(session, 6, "app.refresh", "{}")
        try await Task.sleep(nanoseconds: 600_000_000)
        box.used = 96
        _ = try await call(session, 7, "app.refresh", "{}")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(posts().count, 1, "a denied client got a notification")
        let hourFormat = await server.engine.clientHourFormat
        XCTAssertEqual(hourFormat, "24h")
        try await session.close()
        XCTAssertFalse(session.raw.contains(canary))
    }

    /// The Qt page needs: provider form data, the live identity, free space, notices, rows, homes, and a slim history.
    func testPageNeeds() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let file = paths.userHome.appending(path: ".config/manicode/credentials.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"default":{"id":"u-1","email":"ada@mail.example","authToken":"\#(canary)"}}"#.utf8).write(to: file)
        let session = try session(manager: manager)

        let listReply = try await call(session, 1, "providers.list", "{}")
        let providers = try XCTUnwrap(listReply["result"] as? [[String: Any]])
        let codebuff = try XCTUnwrap(providers.first { $0["id"] as? String == "codebuff" })
        XCTAssertEqual(codebuff["style"] as? String, "files")
        XCTAssertEqual(codebuff["signedIn"] as? Bool, true)
        XCTAssertNotNil(codebuff["dashboard"] as? String)
        let secret = try XCTUnwrap(providers.first { ($0["fields"] as? [Any])?.isEmpty == false })
        XCTAssertEqual(secret["style"] as? String, "secret")

        let live = try await call(session, 2, "providers.liveIdentity", #"{"providerID":"codebuff"}"#)
        XCTAssertEqual(result(live)?["label"] as? String, "ada@mail", "the email follows the privacy default")
        let none = try await call(session, 3, "providers.liveIdentity", #"{"providerID":"kimi"}"#)
        XCTAssertTrue(result(none)?["label"] is NSNull)

        let free = try await call(session, 4, "backup.freeSpace", #"{"path":"\#(root.path)/not/yet/made"}"#)
        XCTAssertGreaterThan(result(free)?["bytes"] as? Int ?? 0, 0)
        let emptyPath = try await call(session, 5, "backup.freeSpace", #"{"path":""}"#)
        XCTAssertEqual(errorCode(emptyPath), -32602)

        let history = try await call(session, 6, "usage.history", #"{"period":"week","points":false}"#)
        XCTAssertNil(result(history)?["points"])
        XCTAssertNotNil(result(history)?["summary"])

        await session.server.engine.setError("Broken")
        await session.server.engine.setNotice("Hello")
        _ = try await call(session, 7, "notices.dismiss", #"{"which":"error"}"#)
        let notices = await session.server.engine.notices
        XCTAssertEqual(notices.notice, "Hello")
        XCTAssertNil(notices.error)
        let badDismiss = try await call(session, 8, "notices.dismiss", #"{"which":"x"}"#)
        XCTAssertEqual(errorCode(badDismiss), -32602)

        let app = await session.server.engine.app
        XCTAssertEqual(app.homes["droid"], paths.droidHome.path)
        try await session.close()
        XCTAssertFalse(session.raw.contains(canary))
    }

    /// History: a role mask, Markdown blocks, and an unchanged list answered without threads.
    func testHistoryRolesBlocksAndRevision() async throws {
        try writeConversation()
        let session = try session()
        let firstReply = try await call(session, 1, "history.list", "{}")
        let first = try XCTUnwrap(result(firstReply))
        let revision = try XCTUnwrap(first["libraryRevision"] as? Int)
        let id = try XCTUnwrap((first["threads"] as? [[String: Any]])?.first?["id"] as? String)
        let againReply = try await call(session, 2, "history.list", #"{"libraryRevision":\#(revision)}"#)
        XCTAssertEqual(result(againReply)?["unchanged"] as? Bool, true)
        XCTAssertEqual((result(againReply)?["threads"] as? [Any])?.count, 0)

        let bothReply = try await call(session, 3, "history.detail", #"{"id":"\#(id)","roles":3}"#)
        let messages = try XCTUnwrap(result(bothReply)?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["text"] as? String }, ["Hello RPC", "Hello back"])
        XCTAssertEqual((messages.first?["blocks"] as? [[String: Any]])?.first?["kind"] as? String, "paragraph")
        let promptsReply = try await call(session, 4, "history.detail", #"{"id":"\#(id)","roles":1,"role":"responses"}"#)
        XCTAssertEqual((result(promptsReply)?["messages"] as? [[String: Any]])?.count, 1, "roles wins over role")
        let bad = try await call(session, 5, "history.detail", #"{"id":"\#(id)","roles":16}"#)
        XCTAssertEqual(errorCode(bad), -32602)
        try await session.close()
    }

    func testHistoryDetailCarriesMarkdownBlocks() {
        let blocks = ChatBlock.parse(ChatMessage(id: "m", role: .assistant, text: "# Title\n\n- a\n- b", timestamp: nil))
        XCTAssertEqual(blocks.map(\.kind), ["heading", "unorderedList"])
        let data = try? JSONEncoder().encode(blocks)
        XCTAssertFalse(String(decoding: data ?? Data(), as: UTF8.self).isEmpty)
    }
}
