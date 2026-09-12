import Foundation
import XCTest
@testable import AIManagerCore

final class OperationLockContractTests: XCTestCase {
    func testManagerRejectsSymbolicLinkLockWithoutChangingTarget() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "iia-directeur-lock-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let support = root.appending(path: "support")
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        try Data("unchanged".utf8).write(to: target)
        try fileManager.createSymbolicLink(
            at: support.appending(path: "manager.lock"), withDestinationURL: target)

        let paths = ManagerPaths(
            applicationSupport: support,
            defaultHome: root.appending(path: "default"),
            sharedRoot: root.appending(path: "shared"),
            orcaAccountsRoot: root.appending(path: "orca"),
            isolationRoot: root
        )
        XCTAssertThrowsError(try AccountManager(paths: paths)) { error in
            XCTAssertEqual(error as? AIManagerError, .unsafePath("operation lock is a symbolic link"))
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
    }
}
