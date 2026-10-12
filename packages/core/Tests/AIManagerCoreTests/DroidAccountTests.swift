import Foundation
import XCTest
@testable import AIManagerCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DroidAccountTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fm = FileManager.default
    private enum Interrupted: Error { case fault }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "DroidAccountTests-\(UUID().uuidString)")
        try CoreSupport.privateDirectory(root, fileManager: fm)
        let fake = root.appending(path: "fake-droid")
        // Opaque synthetic bytes only. This executable cannot call Droid or the Keychain.
        let script = """
        #!/bin/sh
        set -eu
        umask 077
        test -n "$FACTORY_HOME_OVERRIDE"
        test -z "${FACTORY_API_KEY:-}"
        mkdir -p "$FACTORY_HOME_OVERRIDE/.factory"
        printf 'synthetic-login-B' > "$FACTORY_HOME_OVERRIDE/.factory/auth.v2.loginkeychain"
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        paths = .init(applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "user/.switch/codex"),
            defaultHome: root.appending(path: "user/.codex"), sharedRoot: root.appending(path: "user/.codex"),
            orcaAccountsRoot: root.appending(path: "orca"), droidExecutable: fake, isolationRoot: root)
        try writeLogin(paths.droidHome, value: "synthetic-login-A")
    }

    override func tearDownWithError() throws {
        if let root { try fm.removeItem(at: root) }
    }

    private func manager(fault: FaultPoint? = nil, processes: [DroidProcess] = []) throws -> AccountManager {
        try AccountManager(paths: paths, writerCheck: { _ in .inactive },
            faultInjector: { if $0 == fault { throw Interrupted.fault } }, droidProcessLister: { processes })
    }

    private func writeLogin(_ home: URL, value: String, fallback: Bool = false) throws {
        try CoreSupport.privateDirectory(home, fileManager: fm)
        for name in DroidProviderAdapter.authNames where CoreSupport.entryExists(home.appending(path: name)) {
            try fm.removeItem(at: home.appending(path: name))
        }
        try CoreSupport.atomicWrite(Data(value.utf8), to: home.appending(path: fallback ? "auth.v2.file" : "auth.v2.loginkeychain"), fileManager: fm)
        if fallback { try CoreSupport.atomicWrite(Data("synthetic-key".utf8), to: home.appending(path: "auth.v2.key"), fileManager: fm) }
    }

    private func accounts(_ manager: AccountManager) async throws -> (AccountRecord, AccountRecord) {
        let first = try await manager.importDroidAccount(name: "Personal")
        let start = try await manager.startAccountLogin(providerID: .droid)
        let exit = try await manager.run(start.launchSpec)
        XCTAssertEqual(exit, 0)
        let check = try await manager.checkAccountLogin(id: start.session.id, droidName: "Work")
        return (first, try XCTUnwrap(check.account))
    }

    func testImportOpaqueLoginAndPrivateCopiesWithoutChangingLiveFiles() async throws {
        let manager = try manager()
        let history = paths.droidHome.appending(path: "sessions-index.json")
        try Data("keep history".utf8).write(to: history)
        let account = try await manager.importDroidAccount(name: "Personal")
        XCTAssertEqual(account.identity.accountID, "Personal")
        XCTAssertNil(account.identity.email)
        XCTAssertEqual(account.credentialFile, paths.droidCredentialStore.appending(path: account.id.uuidString))
        XCTAssertEqual(try Data(contentsOf: account.credentialFile.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-A".utf8))
        XCTAssertEqual(try Data(contentsOf: history), Data("keep history".utf8))
        XCTAssertEqual((try fm.attributesOfItem(atPath: account.credentialFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try fm.attributesOfItem(atPath: account.credentialFile.appending(path: "auth.v2.loginkeychain").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID(for: .droid), account.id)
        XCTAssertNil(status.defaultAccountID)
    }

    func testSwitchCapturesRotatedOutgoingFilesAndPreservesHistory() async throws {
        let manager = try manager()
        let (first, second) = try await accounts(manager)
        try writeLogin(paths.droidHome, value: "rotated-A", fallback: true)
        let history = paths.droidHome.appending(path: "state/history.json")
        try CoreSupport.privateDirectory(history.deletingLastPathComponent(), fileManager: fm)
        try Data("unchanged".utf8).write(to: history)
        _ = try await manager.switchDefault(to: second.id)
        XCTAssertEqual(try Data(contentsOf: first.credentialFile.appending(path: "auth.v2.file")), Data("rotated-A".utf8))
        XCTAssertFalse(CoreSupport.entryExists(paths.droidHome.appending(path: "auth.v2.key")))
        XCTAssertFalse(CoreSupport.entryExists(paths.droidHome.appending(path: "auth.v2.file")))
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-B".utf8))
        _ = try await manager.switchDefault(to: first.id)
        XCTAssertFalse(CoreSupport.entryExists(paths.droidHome.appending(path: "auth.v2.loginkeychain")))
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.file")), Data("rotated-A".utf8))
        XCTAssertEqual(try Data(contentsOf: history), Data("unchanged".utf8))
    }

    func testWriteLockMatchesDroidOwnerProtocolAndRefusesCompetingWriter() throws {
        let adapter = DroidProviderAdapter(fileManager: fm)
        try adapter.withWriteLock(home: paths.droidHome) {
            let lock = paths.droidHome.appending(path: "auth.v2.write.lock")
            let owner = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: lock.appending(path: "owner.json"))) as? [String: Any])
            XCTAssertEqual(owner["pid"] as? Int, Int(getpid()))
            XCTAssertNotNil(owner["token"] as? String)
            XCTAssertThrowsError(try adapter.withWriteLock(home: paths.droidHome) {}) { XCTAssertEqual($0 as? DroidAccountError, .writeLockBusy) }
        }
        XCTAssertFalse(CoreSupport.entryExists(paths.droidHome.appending(path: "auth.v2.write.lock")))
        try CoreSupport.privateDirectory(paths.droidHome.appending(path: "auth.v2.write.lock.reclaim"), fileManager: fm)
        XCTAssertThrowsError(try adapter.withWriteLock(home: paths.droidHome) {})
    }

    func testRecoveryRollsBackPartialSwitchAfterPublicationFault() async throws {
        let manager = try manager()
        let (first, second) = try await accounts(manager)
        try writeLogin(paths.droidHome, value: "rotated-A", fallback: true)
        let broken = try self.manager(fault: .afterDefaultCredentialPublication)
        do { _ = try await broken.switchDefault(to: second.id); XCTFail("fault did not fire") } catch Interrupted.fault {}
        let recovered = try await manager.recover()
        XCTAssertEqual(recovered.first?.outcome, .rolledBack)
        XCTAssertEqual(try DroidProviderAdapter(fileManager: fm).files(in: paths.droidHome)["auth.v2.file"], Data("rotated-A".utf8))
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID(for: .droid), first.id)
        XCTAssertTrue(status.pendingRecovery.isEmpty)
    }

    func testRecoveryFinalizesCommittedSwitchWithRemovedFiles() async throws {
        let manager = try manager()
        let (_, second) = try await accounts(manager)
        try writeLogin(paths.droidHome, value: "rotated-A", fallback: true)
        let broken = try self.manager(fault: .afterRegistryCommit)
        do { _ = try await broken.switchDefault(to: second.id); XCTFail("fault did not fire") } catch Interrupted.fault {}
        let recovered = try await manager.recover()
        XCTAssertEqual(recovered.first?.outcome, .completed)
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID(for: .droid), second.id)
        XCTAssertTrue(status.pendingRecovery.isEmpty)
    }

    func testRecoveryRollsBackInterruptedOutgoingCapture() async throws {
        let manager = try manager()
        let (_, second) = try await accounts(manager)
        let broken = try self.manager(fault: .afterTemporaryCopy)
        do { _ = try await broken.switchDefault(to: second.id); XCTFail("fault did not fire") } catch Interrupted.fault {}
        let results = try await manager.recover()
        XCTAssertEqual(results.first?.outcome, .rolledBack)
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-A".utf8))
    }

    func testRunningAppGuardIsTypedAndDoesNotChangeAnyFiles() async throws {
        let manager = try manager()
        let (_, second) = try await accounts(manager)
        let process = DroidProcess(pid: 42, bundleID: "com.electron.factory", home: paths.droidHome)
        let guarded = try self.manager(processes: [process])
        do { _ = try await guarded.switchDefault(to: second.id); XCTFail("guard was skipped") }
        catch let error as DroidAccountError { XCTAssertEqual(error, .running([process])) }
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-A".utf8))
        _ = try await guarded.switchDefault(to: second.id, allowRunningDroid: true)
        let unrelated = try self.manager(processes: [.init(pid: 43, home: root.appending(path: "other/.factory"))])
        _ = try await unrelated.switchDefault(to: second.id)
    }

    func testOnlyOneLoginAtATimeIncludingAfterRestartAndCancellation() async throws {
        let manager = try manager()
        let first = try await manager.startAccountLogin(providerID: .droid)
        XCTAssertTrue(first.opensInTerminal)
        XCTAssertEqual(first.launchSpec.executable, paths.droidExecutable)
        XCTAssertNotEqual(first.launchSpec.environment["FACTORY_HOME_OVERRIDE"], paths.droidHome.deletingLastPathComponent().path)
        let restarted = try self.manager()
        do { _ = try await restarted.startAccountLogin(providerID: .droid); XCTFail("duplicate login") }
        catch let error as DroidAccountError { XCTAssertEqual(error, .loginInProgress) }
        try await manager.cancelAccountLogin(id: first.session.id)
        _ = try await restarted.startAccountLogin(providerID: .droid)
    }

    func testLoginRefusedWithoutExistingFactoryLogin() async throws {
        try fm.removeItem(at: paths.droidHome.appending(path: "auth.v2.loginkeychain"))
        let manager = try manager()
        do { _ = try await manager.startAccountLogin(providerID: .droid); XCTFail("must refuse") }
        catch let error as DroidAccountError { XCTAssertEqual(error, .existingLoginRequired) }
        let snapshot = try await manager.refreshAccounts(includeDiscoveries: false)
        XCTAssertTrue(snapshot.pendingLoginSessions.isEmpty)
    }

    func testAccountScopedSignInRequiresNamedConfirmationAndPreservesOtherAccounts() async throws {
        let manager = try manager()
        let (first, second) = try await accounts(manager)
        do { _ = try await manager.startAccountLogin(accountID: first.id); XCTFail("confirmation required") }
        catch let error as DroidAccountError { XCTAssertEqual(error, .confirmSignIn("Personal")) }
        let before = try Data(contentsOf: second.credentialFile.appending(path: "auth.v2.loginkeychain"))
        let start = try await manager.startAccountLogin(accountID: first.id, confirmDroidAccount: true)
        _ = try await manager.run(start.launchSpec)
        let check = try await manager.checkAccountLogin(id: start.session.id)
        XCTAssertEqual(check.account?.id, first.id)
        XCTAssertEqual(check.account?.identity.accountID, "Personal")
        XCTAssertEqual(try Data(contentsOf: second.credentialFile.appending(path: "auth.v2.loginkeychain")), before)
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-B".utf8))
        _ = try await manager.switchDefault(to: first.id)
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-B".utf8))
    }

    func testRejectsSymlinkAndIncompleteFallbackWithoutReadingTargets() async throws {
        let login = paths.droidHome.appending(path: "auth.v2.loginkeychain")
        try fm.removeItem(at: login)
        try fm.createSymbolicLink(at: login, withDestinationURL: root.appending(path: "do-not-read"))
        let manager = try manager()
        do { _ = try await manager.importDroidAccount(name: "Unsafe"); XCTFail("symlink accepted") } catch AIManagerError.credentialConflict {}
        try fm.removeItem(at: login)
        try CoreSupport.atomicWrite(Data("incomplete".utf8), to: paths.droidHome.appending(path: "auth.v2.file"), fileManager: fm)
        do { _ = try await manager.importDroidAccount(name: "Unsafe"); XCTFail("missing key accepted") } catch AIManagerError.credentialConflict {}
    }

    func testUsageRequiresAccountAPIKeyAndReusesFactoryProvider() async throws {
        let factory = ProviderSpec(id: "factory", name: "Factory", usage: { credential in
            XCTAssertEqual(try credential.require("apiKey"), "synthetic-usage-key")
            XCTAssertTrue(credential.files.isEmpty)
            return ProviderUsage(windows: [.init(id: "session", title: "5-hour", usedPercent: 25)])
        })
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive },
                                         providerSpecs: [factory], droidProcessLister: { [] })
        let account = try await manager.importDroidAccount(name: "Usage test")
        do { _ = try await manager.readProviderUsage(accountID: account.id); XCTFail("usage without key") }
        catch ProviderError.unsupported {}
        try await manager.setDroidUsageAPIKey(accountID: account.id, apiKey: "synthetic-usage-key")
        let usage = try await manager.readProviderUsage(accountID: account.id)
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
        try await manager.setDroidUsageAPIKey(accountID: account.id, apiKey: "")
        XCTAssertFalse(CoreSupport.entryExists(paths.applicationSupport.appending(path: "droid-usage/\(account.id.uuidString).json")))
    }

    func testEnvironmentAppendsFactoryDirectoryAndKeepsIsolation() {
        let home = root.appending(path: "isolated")
        let isolated = ManagerPaths.environment(["AI_MANAGER_ROOT": home.path, "FACTORY_HOME_OVERRIDE": home.path])
        XCTAssertEqual(isolated.droidHome, home.appending(path: ".factory"))
        let rejected = ManagerPaths.environment(["AI_MANAGER_ROOT": home.path, "FACTORY_HOME_OVERRIDE": "/outside-test-home"])
        XCTAssertEqual(rejected.droidHome, home.appending(path: ".factory"))
    }

    func testLoginPollWaitsForDroidWriterLock() async throws {
        let manager = try manager()
        let start = try await manager.startAccountLogin(providerID: .droid)
        _ = try await manager.run(start.launchSpec)
        let home = URL(fileURLWithPath: try XCTUnwrap(start.launchSpec.environment["FACTORY_HOME_OVERRIDE"]))
            .appending(path: ".factory")
        let lock = home.appending(path: "auth.v2.write.lock")
        try CoreSupport.privateDirectory(lock, fileManager: fm)
        let waiting = try await manager.checkAccountLogin(id: start.session.id, droidName: "Work")
        XCTAssertEqual(waiting.state, .waitingForLogin)
        try fm.removeItem(at: lock)
        let completed = try await manager.checkAccountLogin(id: start.session.id, droidName: "Work")
        XCTAssertEqual(completed.state, .completed)
    }

    func testDefaultSignInRecoveryRestoresSavedAndLiveLoginTogether() async throws {
        let manager = try manager()
        let first = try await manager.importDroidAccount(name: "Personal")
        let start = try await manager.startAccountLogin(accountID: first.id, confirmDroidAccount: true)
        _ = try await manager.run(start.launchSpec)
        let broken = try self.manager(fault: .afterDefaultCredentialPublication)
        do { _ = try await broken.checkAccountLogin(id: start.session.id); XCTFail("fault did not fire") }
        catch Interrupted.fault {}
        let recovered = try await manager.recover()
        XCTAssertEqual(recovered.first?.outcome, .rolledBack)
        XCTAssertEqual(try Data(contentsOf: first.credentialFile.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-A".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-A".utf8))
        let checked = try await manager.checkAccountLogin(id: start.session.id)
        XCTAssertEqual(checked.account?.id, first.id)
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-B".utf8))
    }

    func testDefaultSignInGuardKeepsBothCopiesUntilConfirmed() async throws {
        let manager = try manager()
        let first = try await manager.importDroidAccount(name: "Personal")
        let start = try await manager.startAccountLogin(accountID: first.id, confirmDroidAccount: true)
        _ = try await manager.run(start.launchSpec)
        let process = DroidProcess(pid: 42)
        let guarded = try self.manager(processes: [process])
        do { _ = try await guarded.checkAccountLogin(id: start.session.id); XCTFail("guard was skipped") }
        catch let error as DroidAccountError { XCTAssertEqual(error, .running([process])) }
        XCTAssertEqual(try Data(contentsOf: first.credentialFile.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-A".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-A".utf8))
        let completed = try await guarded.checkAccountLogin(id: start.session.id, allowRunningDroid: true)
        XCTAssertEqual(completed.state, .completed)
    }

    func testNonDefaultSignInRefreshesOnlyItsSavedCopy() async throws {
        let manager = try manager()
        let (first, second) = try await accounts(manager)
        _ = try await manager.switchDefault(to: second.id)
        let start = try await manager.startAccountLogin(accountID: first.id, confirmDroidAccount: true)
        let home = URL(fileURLWithPath: try XCTUnwrap(start.launchSpec.environment["FACTORY_HOME_OVERRIDE"]))
            .appending(path: ".factory")
        try writeLogin(home, value: "refreshed-A")
        let completed = try await manager.checkAccountLogin(id: start.session.id)
        XCTAssertEqual(completed.account?.id, first.id)
        XCTAssertEqual(try Data(contentsOf: first.credentialFile.appending(path: "auth.v2.loginkeychain")), Data("refreshed-A".utf8))
        XCTAssertEqual(try Data(contentsOf: second.credentialFile.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-B".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-B".utf8))
    }
}
