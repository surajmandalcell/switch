import Foundation

@main
enum SingleInstanceCheck {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--expect-blocked" {
            exit(AIManagerInstanceLock(bundleIdentifier: CommandLine.arguments[2]) == nil ? 0 : 1)
        }

        let identifier = "com.mandalsuraj.ai-manager.test.\(ProcessInfo.processInfo.processIdentifier)"
        var owner: AIManagerInstanceLock? = AIManagerInstanceLock(bundleIdentifier: identifier)
        guard owner != nil else { fatalError("First process did not acquire the instance lock") }

        let duplicate = Process()
        duplicate.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        duplicate.arguments = ["--expect-blocked", identifier]
        try duplicate.run()
        duplicate.waitUntilExit()
        guard duplicate.terminationStatus == 0 else {
            fatalError("A second process acquired the instance lock")
        }

        owner = nil
        guard AIManagerInstanceLock(bundleIdentifier: identifier) != nil else {
            fatalError("The instance lock did not release with its owner")
        }
        print("SINGLE_INSTANCE_CHECK_PASS")
    }
}
