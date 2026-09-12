import Darwin
import Foundation
import XCTest
@testable import AIManagerCore

final class FilesystemFailureContractTests: XCTestCase {
    private let fileManager = FileManager.default
    private var root: URL!
    private var paths: ManagerPaths!

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "AIManagerFilesystemFailures-\(UUID().uuidString)")
        paths = .init(
            applicationSupport: root.appending(path: "support"),
            defaultHome: root.appending(path: "default"),
            sharedRoot: root.appending(path: "shared"),
            orcaAccountsRoot: root.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            isolationRoot: root
        )
        try fileManager.createDirectory(at: paths.defaultHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.sharedRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    func testDeniedSourcePathFailsClosedWithoutCreatingAnAccount() async throws {
        let source = root.appending(path: "denied-source")
        try writeAuth(home: source, account: "denied")
        let auth = source.appending(path: "auth.json")
        XCTAssertEqual(chmod(source.path, 0), 0)
        defer { _ = chmod(source.path, S_IRWXU) }

        errno = 0
        let descriptor = open(auth.path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            XCTFail("The synthetic denied source remained readable; EACCES could not be simulated")
            return
        }
        XCTAssertEqual(errno, EACCES)

        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        await XCTAssertThrowsFilesystemError(try await manager.planImport(source: source, mode: .authOnly))
        let status = try await manager.status()
        XCTAssertTrue(status.accounts.isEmpty)
        XCTAssertTrue(status.pendingRecovery.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: paths.defaultHome.appending(path: "auth.json").path))
    }

    func testDisconnectedSourceAfterReviewPreservesPriorAccountAndDefault() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let prior = try await importAndSelect(account: "prior", manager: manager)
        let priorDefault = try Data(contentsOf: paths.defaultHome.appending(path: "auth.json"))
        let disconnected = root.appending(path: "disconnected-source")
        try writeAuth(home: disconnected, account: "incoming")
        let plan = try await manager.planImport(source: disconnected, mode: .authOnly)

        try fileManager.removeItem(at: disconnected)
        await XCTAssertThrowsFilesystemError(try await manager.importAccount(plan: plan)) { error in
            XCTAssertEqual(error as? AIManagerError, .sourceChanged)
        }

        let status = try await manager.status()
        XCTAssertEqual(status.accounts.map(\.id), [prior.id])
        XCTAssertEqual(status.defaultAccountID, prior.id)
        XCTAssertTrue(status.pendingRecovery.isEmpty)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), priorDefault)
        XCTAssertFalse(fileManager.fileExists(atPath: plan.destination.path))
    }

    func testSimulatedDiskFullAfterJournaledSettingMutationRecoversWithoutHalfAccount() async throws {
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let prior = try await importAndSelect(account: "prior", manager: setup)
        let priorDefault = try Data(contentsOf: paths.defaultHome.appending(path: "auth.json"))
        let source = root.appending(path: "disk-full-source")
        try writeAuth(home: source, account: "incoming")
        let sourceConfig = Data("synthetic-setting".utf8)
        try sourceConfig.write(to: source.appending(path: "config.toml"))
        let sourceAuth = try Data(contentsOf: source.appending(path: "auth.json"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .duringHistoryCopy {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: [NSLocalizedDescriptionKey: "simulated disk full"])
            }
        })
        let plan = try await manager.planImport(source: source, mode: .full)

        await XCTAssertThrowsFilesystemError(try await manager.importAccount(plan: plan)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(nsError.code, Int(ENOSPC))
        }
        XCTAssertEqual(try Data(contentsOf: source.appending(path: "auth.json")), sourceAuth)
        XCTAssertEqual(try Data(contentsOf: source.appending(path: "config.toml")), sourceConfig)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), priorDefault)
        let interruptedStatus = try await manager.status()
        XCTAssertEqual(interruptedStatus.pendingRecovery.count, 1)

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let recovery = try await recovering.recover()
        XCTAssertEqual(recovery.first?.outcome, .rolledBack)
        let status = try await recovering.status()
        XCTAssertEqual(status.accounts.map(\.id), [prior.id])
        XCTAssertEqual(status.defaultAccountID, prior.id)
        XCTAssertTrue(status.pendingRecovery.isEmpty)
        XCTAssertFalse(CoreSupport.entryExists(paths.sharedRoot.appending(path: "config.toml")))
        XCTAssertFalse(fileManager.fileExists(atPath: plan.destination.path))
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), priorDefault)
    }

    private func importAndSelect(account: String, manager: AccountManager) async throws -> AccountRecord {
        let source = root.appending(path: "source-\(account)")
        try writeAuth(home: source, account: account)
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let imported = try await manager.importAccount(plan: plan).account
        _ = try await manager.switchDefault(to: imported.id)
        return imported
    }

    private func writeAuth(home: URL, account: String) throws {
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let claims = try JSONSerialization.data(withJSONObject: [
            "email": "\(account)@example.test",
            "chatgpt_user_id": "user-\(account)",
            "chatgpt_account_id": account,
            "workspace_id": "workspace"
        ])
        .base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        let auth: [String: Any] = [
            "last_refresh": "synthetic",
            "tokens": [
                "access_token": "header.\(claims).signature",
                "account_id": account,
                "refresh_token": "synthetic"
            ]
        ]
        try JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys]).write(to: home.appending(path: "auth.json"))
    }
}

private func XCTAssertThrowsFilesystemError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected a filesystem failure", file: file, line: line)
    } catch {
        handler(error)
    }
}
