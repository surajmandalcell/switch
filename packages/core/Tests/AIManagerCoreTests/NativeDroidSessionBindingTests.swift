import Foundation
import XCTest

final class NativeDroidSessionBindingTests: XCTestCase {
    func testSwitchKeepsOriginalConversationResumableUsingTheNativeCLI() async throws {
        guard let binary = ProcessInfo.processInfo.environment["SWITCH_TEST_DROID_EXECUTABLE"] else {
            throw XCTSkip("Set SWITCH_TEST_DROID_EXECUTABLE and the loopback-only Factory environment for the isolated native CLI check.")
        }
        try await NativeDroidResumeCheck.run(executable: binary)
    }
}
