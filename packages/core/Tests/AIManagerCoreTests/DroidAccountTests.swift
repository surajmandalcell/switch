import Foundation
import XCTest
@testable import AIManagerCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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
        if test "${1:-}" = doctor; then
          test "$2" = --auth
          test "$3" = --json
          fake_root=$(dirname "$0")
          printf '%s\\n%s\\n%s\\n' "$FACTORY_HOME_OVERRIDE" "$FACTORY_DISABLE_KEYRING" "$0" > "$fake_root/doctor-invocation"
          # A simulated token refresh rewrites the login in place, as the real doctor can.
          test ! -f "$fake_root/doctor-rewrite" || cp "$fake_root/doctor-rewrite" "$FACTORY_HOME_OVERRIDE/.factory/auth.v2.loginkeychain"
          test -f "$fake_root/doctor.json" || exit 1
          cat "$fake_root/doctor.json"
          exit 0
        fi
        mkdir -p "$FACTORY_HOME_OVERRIDE/.factory"
        printf 'synthetic-login-B' > "$FACTORY_HOME_OVERRIDE/.factory/auth.v2.loginkeychain"
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let bundled = root.appending(path: "bundled-droid")
        try fm.copyItem(at: fake, to: bundled)
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

    private func doctor(_ hint: String, status: String = "pass") throws {
        let data = try JSONSerialization.data(withJSONObject: ["results": [
            ["id": "auth.verify", "status": status, "detail": "authenticated as \(hint) via stored login session"]
        ]])
        try CoreSupport.atomicWrite(data, to: root.appending(path: "doctor.json"), fileManager: fm)
    }

    func testDoctorParsesOnlyPassingMaskedStoredLogin() throws {
        try doctor("S***@gmail.com")
        let data = try Data(contentsOf: root.appending(path: "doctor.json"))
        XCTAssertEqual(DroidProviderAdapter.identityHint(data), "s***@gmail.com")
        for hint in ["full@gmail.com", "bad***@", "s***@gmail.com extra", "s***@gmail.com\n"] {
            try doctor(hint)
            XCTAssertNil(DroidProviderAdapter.identityHint(try Data(contentsOf: root.appending(path: "doctor.json"))))
        }
        try doctor("s***@gmail.com", status: "fail")
        XCTAssertNil(DroidProviderAdapter.identityHint(try Data(contentsOf: root.appending(path: "doctor.json"))))
        XCTAssertNil(DroidProviderAdapter.identityHint(Data("unknown".utf8)))
    }

    func testDoctorImportStoresHintOnTheSourceHomeAndMatchingKeyringMode() async throws {
        try doctor("s***@gmail.com")
        let manager = try manager()
        let account = try await manager.importDroidAccount(name: "Personal")
        XCTAssertEqual(account.identity.email, "s***@gmail.com")
        var invocation = try String(contentsOf: root.appending(path: "doctor-invocation"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(String(invocation[0]), paths.droidHome.deletingLastPathComponent().path)
        XCTAssertEqual(invocation[1], "0")
        try writeLogin(paths.droidHome, value: "fallback", fallback: true)
        try doctor("d***@gmail.com")
        _ = try await manager.importDroidAccount(name: "Work")
        invocation = try String(contentsOf: root.appending(path: "doctor-invocation"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(invocation[1], "1")
    }

    func testDoctorNeverRunsOnACopyAndSavedCopyHoldsRefreshedBytes() async throws {
        try doctor("s***@gmail.com")
        try CoreSupport.atomicWrite(Data("refreshed-login".utf8), to: root.appending(path: "doctor-rewrite"), fileManager: fm)
        let manager = try manager()
        let account = try await manager.importDroidAccount(name: "Personal")
        let invocation = try String(contentsOf: root.appending(path: "doctor-invocation"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(String(invocation[0]), paths.droidHome.deletingLastPathComponent().path)
        XCTAssertEqual(try Data(contentsOf: account.credentialFile.appending(path: "auth.v2.loginkeychain")), Data("refreshed-login".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("refreshed-login".utf8))
        let staging = paths.applicationSupport.appending(path: "staging")
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: staging.path)) ?? [], [])
        XCTAssertFalse(CoreSupport.entryExists(paths.droidHome.appending(path: "doctor-output.json")))
        // Re-sign-in: doctor runs on the staging home and its refreshed bytes are saved.
        let start = try await manager.startAccountLogin(accountID: account.id, confirmDroidAccount: true)
        _ = try await manager.run(start.launchSpec)
        try CoreSupport.atomicWrite(Data("refreshed-staging".utf8), to: root.appending(path: "doctor-rewrite"), fileManager: fm)
        let check = try await manager.checkAccountLogin(id: start.session.id)
        let staged = String(try String(contentsOf: root.appending(path: "doctor-invocation"), encoding: .utf8).split(separator: "\n")[0])
        XCTAssertNotEqual(staged, paths.droidHome.deletingLastPathComponent().path)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(check.account).credentialFile.appending(path: "auth.v2.loginkeychain")), Data("refreshed-staging".utf8))
    }

    func testLiveHomeImportPrefersBundledDroidButStagingKeepsResolved() async throws {
        try doctor("s***@gmail.com")
        let bundled = root.appending(path: "bundled-droid")
        paths.droidBundledExecutable = bundled
        let manager = try manager()
        let account = try await manager.importDroidAccount(name: "Personal")
        func executable() throws -> String { String(try String(contentsOf: root.appending(path: "doctor-invocation"), encoding: .utf8).split(separator: "\n")[2]) }
        XCTAssertEqual(try executable(), bundled.resolvingSymlinksInPath().path)
        let start = try await manager.startAccountLogin(accountID: account.id, confirmDroidAccount: true)
        _ = try await manager.run(start.launchSpec)
        _ = try await manager.checkAccountLogin(id: start.session.id)
        XCTAssertEqual(try executable(), root.appending(path: "fake-droid").resolvingSymlinksInPath().path)
    }

    func testDoctorMismatchRejectsAndDiscardsStagingWithoutChangingAccountOrLive() async throws {
        try doctor("s***@gmail.com")
        let manager = try manager()
        let account = try await manager.importDroidAccount(name: "Personal")
        let before = try await manager.status()
        let start = try await manager.startAccountLogin(accountID: account.id, confirmDroidAccount: true)
        _ = try await manager.run(start.launchSpec)
        try doctor("d***@gmail.com")
        do { _ = try await manager.checkAccountLogin(id: start.session.id); XCTFail("Wrong mask accepted") }
        catch {
            XCTAssertEqual(error as? AIManagerError, .signInIdentityMismatch(signedIn: "d***@gmail.com", target: "s***@gmail.com"))
        }
        XCTAssertFalse(CoreSupport.entryExists(start.launchSpec.workingDirectory!))
        let after = try await manager.status()
        XCTAssertEqual(after.accounts, before.accounts)
        XCTAssertEqual(after.defaultAccountID(for: .droid), account.id)
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-A".utf8))
        let next = try await manager.startAccountLogin(providerID: .droid)
        try await manager.cancelAccountLogin(id: next.session.id)
    }

    func testDoctorMatchingMaskAcceptsAccountScopedRefresh() async throws {
        try doctor("s***@gmail.com")
        let manager = try manager()
        let account = try await manager.importDroidAccount(name: "Personal")
        let start = try await manager.startAccountLogin(accountID: account.id, confirmDroidAccount: true)
        _ = try await manager.run(start.launchSpec)
        let check = try await manager.checkAccountLogin(id: start.session.id)
        XCTAssertEqual(check.account?.id, account.id)
        XCTAssertEqual(check.account?.identity.email, "s***@gmail.com")
        XCTAssertEqual(check.account?.identity.accountID, "Personal")
        XCTAssertEqual(try Data(contentsOf: paths.droidHome.appending(path: "auth.v2.loginkeychain")), Data("synthetic-login-B".utf8))
    }

    func testDoctorFailureAndUnknownFormatFallBackAndPreserveSavedHint() async throws {
        let manager = try manager()
        let fallback = try await manager.importDroidAccount(name: "No hint")
        XCTAssertNil(fallback.identity.email)
        XCTAssertTrue(fallback.verification.detail.contains("could not confirm"))
        try doctor("s***@gmail.com")
        let start = try await manager.startAccountLogin(accountID: fallback.id, confirmDroidAccount: true)
        _ = try await manager.run(start.launchSpec)
        _ = try await manager.checkAccountLogin(id: start.session.id)
        let retry = try await manager.startAccountLogin(accountID: fallback.id, confirmDroidAccount: true)
        _ = try await manager.run(retry.launchSpec)
        try CoreSupport.atomicWrite(Data("{\"results\": []}".utf8), to: root.appending(path: "doctor.json"), fileManager: fm)
        let check = try await manager.checkAccountLogin(id: retry.session.id)
        XCTAssertEqual(check.account?.identity.email, "s***@gmail.com")
        XCTAssertTrue(check.message.contains("could not confirm"))
    }

    func testDuplicateMaskRequiresConfirmationBeforeImportOrNewSignIn() async throws {
        try doctor("s***@gmail.com")
        let manager = try manager()
        let account = try await manager.importDroidAccount(name: "Personal")
        let start = try await manager.startAccountLogin(providerID: .droid)
        _ = try await manager.run(start.launchSpec)
        do { _ = try await manager.checkAccountLogin(id: start.session.id, droidName: "Other"); XCTFail("Duplicate accepted") }
        catch {
            XCTAssertEqual(error as? DroidAccountError, .duplicateIdentity(name: "Personal", hint: "s***@gmail.com"))
            XCTAssertEqual(error.localizedDescription, "This looks like Personal (s***@gmail.com). Add it anyway?")
        }
        let status = try await manager.status()
        XCTAssertEqual(status.accounts.count, 1)
        let check = try await manager.checkAccountLogin(id: start.session.id, droidName: "Other", allowDuplicateDroid: true)
        XCTAssertNotEqual(check.account?.id, account.id)
        do { _ = try await manager.importDroidAccount(name: "Again"); XCTFail("Duplicate import accepted") }
        catch { XCTAssertEqual(error as? DroidAccountError, .duplicateIdentity(name: "Personal", hint: "s***@gmail.com")) }
    }

    private struct SyntheticKey: DroidLoginReader.KeyProvider {
        func key(interactive: Bool) throws -> Data { Data(repeating: 7, count: 32) }
    }

    /// A Keychain-format login sealed with the synthetic key, whose token names `subject`.
    private func sealedLogin(subject: String, nonce: UInt8 = 3) throws -> String {
        let payload = Data("{\"exp\":1,\"sub\":\"\(subject)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let clear = try JSONSerialization.data(withJSONObject: ["access_token": "eyJhbGciOiJub25lIn0.\(payload).synthetic"])
        let box = try AES.GCM.seal(clear, using: SymmetricKey(data: Data(repeating: 7, count: 32)),
                                   nonce: AES.GCM.Nonce(data: Data(repeating: nonce, count: 16)))
        return [Data(box.nonce), box.tag, box.ciphertext].map { $0.base64EncodedString() }.joined(separator: ":")
    }

    func testEqualMasksWithDifferentTokenSubjectsAreDifferentAccounts() async throws {
        try doctor("s***@gmail.com")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, droidProcessLister: { [] },
            droidLoginReader: DroidLoginReader(keyProvider: SyntheticKey()))
        try writeLogin(paths.droidHome, value: sealedLogin(subject: "user_sam"))
        let first = try await manager.importDroidAccount(name: "Sam")
        // An expired token still names its account; a different subject is a different person.
        try writeLogin(paths.droidHome, value: sealedLogin(subject: "user_sara"))
        let added = await manager.importLiveLogins()
        XCTAssertEqual(added.count, 1)
        XCTAssertNotEqual(added.first?.id, first.id)
        try writeLogin(paths.droidHome, value: sealedLogin(subject: "user_sid"))
        let third = try await manager.importDroidAccount(name: "Sid")
        let saved = try await manager.status().accounts.filter { $0.identity.providerID == .droid }
        XCTAssertEqual(saved.count, 3)
        // The same subject with a fresh token is still a possible duplicate.
        try writeLogin(paths.droidHome, value: sealedLogin(subject: "user_sid", nonce: 5))
        do { _ = try await manager.importDroidAccount(name: "Again"); XCTFail("Same subject added without confirmation") }
        catch { XCTAssertEqual(error as? DroidAccountError, .duplicateIdentity(name: third.identity.accountID ?? "", hint: "s***@gmail.com")) }
        let again = await manager.importLiveLogins()
        XCTAssertTrue(again.isEmpty)
    }

    func testRenameChangesOnlyTheDroidName() async throws {
        let manager = try manager()
        let (first, second) = try await accounts(manager)
        let before = try await manager.status()
        let status = try await manager.renameDroidAccount(first.id, to: "  Home laptop  ")
        let renamed = try XCTUnwrap(status.accounts.first { $0.id == first.id })
        XCTAssertEqual(renamed.identity.accountID, "Home laptop")
        XCTAssertEqual(renamed.credentialDigest, first.credentialDigest)
        XCTAssertEqual(renamed.credentialFile, first.credentialFile)
        XCTAssertEqual(status.defaultAccountID(for: .droid), before.defaultAccountID(for: .droid))
        XCTAssertEqual(status.accounts.first { $0.id == second.id }?.identity.accountID, "Work")
        XCTAssertEqual(status.accounts.map(\.id), before.accounts.map(\.id))
        for bad in ["", "   ", "two\nlines", String(repeating: "x", count: 101)] {
            do { _ = try await manager.renameDroidAccount(first.id, to: bad); XCTFail("Accepted the name \(bad.debugDescription)") }
            catch { guard case AIManagerError.invalidSource = error else { return XCTFail("Wrong error \(error)") } }
        }
        do { _ = try await manager.renameDroidAccount(UUID(), to: "Nobody"); XCTFail("Renamed a missing account") }
        catch { guard case AIManagerError.accountNotFound = error else { return XCTFail("Wrong error \(error)") } }
        let reloaded = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, droidProcessLister: { [] })
        let saved = try await reloaded.status().accounts.first { $0.id == first.id }
        XCTAssertEqual(saved?.identity.accountID, "Home laptop")
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

    func testUsageAPIKeyWinsOverUnreadableLoginAndReusesFactoryProvider() async throws {
        let factory = ProviderSpec(id: "factory", name: "Factory", usage: { credential in
            XCTAssertEqual(try credential.require("apiKey"), "synthetic-usage-key")
            XCTAssertTrue(credential.files.isEmpty)
            return ProviderUsage(windows: [.init(id: "session", title: "5-hour", usedPercent: 25)])
        })
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive },
                                         providerSpecs: [factory], droidProcessLister: { [] })
        let account = try await manager.importDroidAccount(name: "Usage test")
        do { _ = try await manager.readProviderUsage(accountID: account.id); XCTFail("usage without key") }
        catch DroidLoginError.invalidLogin {}
        try await manager.setDroidUsageAPIKey(accountID: account.id, apiKey: "synthetic-usage-key")
        let usage = try await manager.readProviderUsage(accountID: account.id)
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
        try await manager.setDroidUsageAPIKey(accountID: account.id, apiKey: "")
        XCTAssertFalse(CoreSupport.entryExists(paths.applicationSupport.appending(path: "droid-usage/\(account.id.uuidString).json")))
    }

    func testHasDroidUsageAPIKeyTracksSavedKey() async throws {
        let manager = try manager()
        let account = try await manager.importDroidAccount(name: "Key state")
        var saved = await manager.hasDroidUsageAPIKey(accountID: account.id)
        XCTAssertFalse(saved)
        try await manager.setDroidUsageAPIKey(accountID: account.id, apiKey: "synthetic-usage-key")
        saved = await manager.hasDroidUsageAPIKey(accountID: account.id)
        XCTAssertTrue(saved)
        try await manager.setDroidUsageAPIKey(accountID: account.id, apiKey: "")
        saved = await manager.hasDroidUsageAPIKey(accountID: account.id)
        XCTAssertFalse(saved)
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

    // MARK: Missions

    /// A synthetic mission folder. `statuses` gives one feature each.
    @discardableResult
    private func mission(
        _ folder: String, created: Date, title: String? = "Synthetic plan", directory: String = "/tmp/synthetic-project",
        statuses: [String] = [], extra: [String: String] = [:]
    ) throws -> URL {
        let url = paths.droidHome.appending(path: "missions/\(folder)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let state: [String: Any] = ["missionId": "mis_\(folder)", "state": "paused", "workingDirectory": directory,
            "createdAt": stamp.string(from: created), "updatedAt": stamp.string(from: created), "futureKey": 1]
        try JSONSerialization.data(withJSONObject: state).write(to: url.appending(path: "state.json"))
        let features = statuses.enumerated().map { index, status -> [String: Any] in
            ["id": "feature-\(index)", "description": "Do thing \(index)", "status": status,
             "expectedBehavior": ["Behaves \(index)"], "milestone": "m1"]
        }
        try JSONSerialization.data(withJSONObject: ["features": features]).write(to: url.appending(path: "features.json"))
        if let title { try "intro\n# \(title)\n\nBody text.\n".write(to: url.appending(path: "mission.md"), atomically: true, encoding: .utf8) }
        for (name, text) in extra { try text.write(to: url.appending(path: name), atomically: true, encoding: .utf8) }
        return url
    }

    func testMissionReaderCountsTitleFallbackAndSkipsBrokenFolders() throws {
        let now = Date()
        try mission("aaaa1111", created: now.addingTimeInterval(-100), statuses: ["completed", "completed", "cancelled", "pending", "weird"])
        try mission("bbbb2222", created: now.addingTimeInterval(-50), title: nil, directory: "/tmp/my-project/app", statuses: ["completed"])
        let broken = try mission("cccc3333", created: now, statuses: ["pending"])
        try Data("{".utf8).write(to: broken.appending(path: "features.json"))
        let noState = paths.droidHome.appending(path: "missions/dddd4444")
        try fm.createDirectory(at: noState, withIntermediateDirectories: true)
        let list = DroidMissionReader.list(droidHome: paths.droidHome)
        XCTAssertEqual(list.map(\.id), ["bbbb2222", "aaaa1111"])
        let first = list[1]
        XCTAssertEqual([first.total, first.completed, first.cancelled, first.left], [5, 2, 1, 2])
        XCTAssertEqual(first.title, "Synthetic plan")
        XCTAssertEqual(first.missionID, "mis_aaaa1111")
        XCTAssertEqual(first.workingDirectory, "/tmp/synthetic-project")
        XCTAssertEqual(list[0].title, "app")
        XCTAssertEqual(list[0].left, 0)
        XCTAssertEqual(first.createdAt.timeIntervalSince1970, now.addingTimeInterval(-100).timeIntervalSince1970, accuracy: 0.01)
        XCTAssertTrue(DroidMissionReader.list(droidHome: root.appending(path: "none")).isEmpty)
    }

    func testMissionOwnersFirstSightRefreshAndChangeOutsideSwitch() {
        let (x, y) = (UUID(), UUID())
        let t = Date(timeIntervalSince1970: 1_000_000)
        func make(_ id: String, _ offset: TimeInterval) -> DroidMission {
            DroidMission(id: id, state: "", workingDirectory: "", createdAt: t.addingTimeInterval(offset),
                         updatedAt: t, title: id, total: 1, completed: 0, cancelled: 0)
        }
        let old = make("old", -10), new = make("new", 10)
        var owners = DroidMissionOwners()
        owners.refresh([old, new], defaultAccount: x, now: t)  // first sight: attributes nothing
        XCTAssertEqual(owners.activeSince, .init(account: x, since: t))
        XCTAssertTrue(owners.owners.isEmpty)
        owners.refresh([old, new], defaultAccount: x, now: t.addingTimeInterval(20))
        XCTAssertEqual(owners.owners, ["new": x])
        owners.refresh([old, new, make("later", 30)], defaultAccount: y, now: t.addingTimeInterval(40))  // changed outside Switch
        XCTAssertEqual(owners.owners, ["new": x])
        XCTAssertEqual(owners.activeSince, .init(account: y, since: t.addingTimeInterval(40)))
        owners.refresh([make("later", 30)], defaultAccount: nil, now: t.addingTimeInterval(50))
        XCTAssertEqual(owners.activeSince?.account, y)
    }

    func testMissionSwitchGivesOldAccountItsMissionsAndManualAndDeletedOwners() async throws {
        let manager = try manager()
        let (first, second) = try await accounts(manager)
        let now = Date()
        try mission("old00000", created: now.addingTimeInterval(-3_600), statuses: ["pending"])
        var list = try await manager.droidMissions()
        XCTAssertNil(list[0].owner)  // first sight: nothing before it is attributed
        try mission("one11111", created: now.addingTimeInterval(60), statuses: ["completed", "pending"])
        try mission("two22222", created: now.addingTimeInterval(120), statuses: ["completed"])
        // The switch gives the missions created under `first` to it, before `second` becomes active.
        let result = try await manager.switchDefault(to: second.id)
        try mission("new33333", created: now.addingTimeInterval(7_200), statuses: ["pending"])
        list = try await manager.droidMissions()
        XCTAssertEqual(list.map(\.id), ["new33333", "two22222", "one11111", "old00000"])
        XCTAssertEqual(list.map(\.owner), [second.id, first.id, first.id, nil])
        let stored = try Data(contentsOf: paths.applicationSupport.appending(path: "droid-missions.json"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let mode = try fm.attributesOfItem(atPath: paths.applicationSupport.appending(path: "droid-missions.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // The notice counts only missions with features left that the old account started.
        let unfinished = try await manager.unfinishedDroidMissions(after: result)
        XCTAssertEqual(unfinished, 1)
        XCTAssertEqual(DroidMissionReader.unfinishedNotice(count: 1, owner: "Personal"),
                       "1 unfinished Droid mission stays with Personal. Resume them from Accounts.")
        XCTAssertEqual(DroidMissionReader.unfinishedNotice(count: 2, owner: "Personal"),
                       "2 unfinished Droid missions stay with Personal. Resume them from Accounts.")
        // Switching to the account that is already the default posts nothing.
        let same = try await manager.switchDefault(to: second.id)
        let none = try await manager.unfinishedDroidMissions(after: same)
        XCTAssertEqual(none, 0)
        // Manual owner.
        try await manager.setDroidMissionOwner(folder: "old00000", accountID: second.id)
        list = try await manager.droidMissions()
        XCTAssertEqual(list.first { $0.id == "old00000" }?.owner, second.id)
        // An owner whose account was deleted reads as unknown.
        _ = try await manager.deleteAccount(accountID: first.id)
        list = try await manager.droidMissions()
        XCTAssertEqual(list.map(\.owner), [second.id, nil, nil, second.id])
    }

    func testMissionPlanListsDoneLeftAndNotes() async throws {
        let manager = try manager()
        _ = try await manager.importDroidAccount(name: "Personal")
        let url = try mission("plan1111", created: Date(), statuses: ["completed", "pending", "cancelled", "in_progress"],
                              extra: ["architecture.md": "arch", "validation-contract.md": "contract"])
        let planURL = try await manager.writeDroidMissionPlan(folder: "plan1111")
        XCTAssertTrue(planURL.path.hasPrefix(paths.applicationSupport.appending(path: "Launch/").path))
        let plan = try String(contentsOf: planURL, encoding: .utf8)
        XCTAssertTrue(plan.contains("started on another Factory account"))
        XCTAssertTrue(plan.contains("Body text."))
        let done = try XCTUnwrap(plan.range(of: "## Done (do not redo)"))
        let left = try XCTUnwrap(plan.range(of: "## Left"))
        let doneText = String(plan[done.upperBound..<left.lowerBound])
        let leftText = String(plan[left.upperBound...])
        XCTAssertTrue(doneText.contains("feature-0: Do thing 0"))
        XCTAssertFalse(doneText.contains("feature-1"))
        XCTAssertTrue(leftText.contains("feature-1: Do thing 1") && leftText.contains("feature-3: Do thing 3"))
        XCTAssertTrue(leftText.contains("- Behaves 1"))
        XCTAssertFalse(leftText.contains("feature-2"))
        XCTAssertTrue(leftText.contains(url.appending(path: "architecture.md").path))
        XCTAssertTrue(leftText.contains(url.appending(path: "validation-contract.md").path))
        do { _ = try await manager.writeDroidMissionPlan(folder: "../escape"); XCTFail("path escaped") } catch {}
    }
}
