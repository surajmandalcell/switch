import Foundation
import AIManagerCore
import SwitchAppModel

#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import CRT
#else
import Glibc
#endif

/// `switch-core doctor`: facts and pass or fail checks for packagers and support. It changes nothing on disk (a
/// missing folder or file is reported, not created) and prints no secret and no account name. Exit 0 only when
/// every check passes.
enum Doctor {
    static func run(paths: ManagerPaths, environment: [String: String]) -> Int32 {
        let root = paths.applicationSupport
        let settingsURL = JSONFileSettingsStore.location(paths: paths, environment: environment)
        let lockURL = root.appending(path: "helper.lock")
        #if os(Linux)
        let platform = "linux"
        #elseif os(Windows)
        let platform = "windows"
        #else
        let platform = "macos"
        #endif
        print("version     \(AIManagerBuildInfo.version)")
        print("platform    \(platform)")
        print("data root   \(root.path)")
        print("settings    \(settingsURL.path) (schema \(SettingsRegistry.schemaVersion))")

        var failures = 0
        func check(_ passed: Bool, _ text: String) {
            print("\(passed ? "pass" : "FAIL")  \(text)")
            if !passed { failures += 1 }
        }

        let rootExists = FileManager.default.fileExists(atPath: root.path)
        if !rootExists {
            check(true, "data root is not created yet; the first start creates it owner-only")
        } else {
            #if os(Windows)
            check(true, "data root owner-only: checked by its ACL when Switch writes (not read here)")
            #else
            var info = stat()
            let read = stat(root.path, &info) == 0
            check(read && info.st_uid == getuid() && info.st_mode & 0o077 == 0,
                  read ? "data root is owner-only (mode \(String(info.st_mode & 0o777, radix: 8)))" : "data root cannot be read")
            #endif
        }

        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsURL.path) {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            settings = object?["values"] as? [String: Any] ?? [:]
            check(object?["schemaVersion"] is Int && object?["values"] is [String: Any], "settings file parses")
        } else {
            check(true, "settings file is not created yet; defaults apply")
        }

        if !rootExists {
            check(true, "helper lock is free (no data root yet)")
        } else if let lock = try? FileLock(at: lockURL) {
            check(true, "helper lock can be taken (no helper runs for this data root)")
            withExtendedLifetime(lock) {}
        } else {
            check(false, "helper lock cannot be taken: a helper runs for this data root, or the lock file is unsafe")
        }

        #if os(Linux)
        let preferred = settings["terminalEmulator"] as? String
        do {
            let command = try TerminalLaunch.emulatorCommand(script: URL(fileURLWithPath: "/dev/null"),
                                                             environment: environment, preferred: preferred)
            check(true, "terminal emulator found: \(command[0])")
        } catch {
            check(false, "no terminal emulator found for sign-ins (install xdg-terminal-exec or xterm, or choose one in Settings)")
        }
        #endif
        print(failures == 0 ? "result      all checks passed" : "result      \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
