import AppKit
import Darwin
import Foundation

final class AIManagerInstanceLock {
    private let descriptor: CInt

    init?(bundleIdentifier: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).instance.lock")
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
    }
}

enum AIManagerSingleInstance {
    static let productionBundleIdentifier = "com.mandalsuraj.ai-manager"

    static func bundleIdentifier() -> String {
        Bundle.main.bundleIdentifier ?? productionBundleIdentifier
    }

    static func activationNotification(bundleIdentifier: String) -> Notification.Name {
        Notification.Name("\(bundleIdentifier).activate-existing-instance")
    }

    @MainActor
    static func acquireOrActivate(bundleIdentifier: String) -> AIManagerInstanceLock? {
        guard let lock = AIManagerInstanceLock(bundleIdentifier: bundleIdentifier) else {
            DistributedNotificationCenter.default().post(
                name: activationNotification(bundleIdentifier: bundleIdentifier), object: nil)
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first { $0.processIdentifier != getpid() }?
                .activate(options: [.activateAllWindows])
            return nil
        }
        return lock
    }
}
