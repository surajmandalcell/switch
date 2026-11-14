import Foundation
import AIManagerCore
import SwitchAppModel
import SwitchRPC

#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import CRT
#else
import Glibc
#endif

/// `switch-core serve [--root <path>]`: the helper the Linux and Windows apps start. It exits 0 when stdin closes
/// or on SIGTERM, after the running requests have their replies. `--root` means the same as `AI_MANAGER_ROOT`:
/// every data folder and home lives under that path.
@main
struct SwitchCore {
    static func main() async {
        var environment = ProcessInfo.processInfo.environment
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.count {
        case 1 where arguments[0] == "serve":
            break
        case 3 where arguments[0] == "serve" && arguments[1] == "--root" && !arguments[2].isEmpty:
            environment["AI_MANAGER_ROOT"] = arguments[2]
        default:
            RPCServer.standardError("Usage: switch-core serve [--root <path>]")
            exit(2)
        }
        let paths = ManagerPaths.environment(environment)

        // One helper per data folder (two would run two schedulers). The OS drops the lock if the helper dies.
        let helperLock: FileLock?
        do {
            // The data folder move runs before the lock file creates the new folder.
            _ = try AppLocations.migrateDataRoot(paths)
            helperLock = try FileLock(at: paths.applicationSupport.appending(path: "helper.lock"))
        } catch {
            RPCServer.standardError("switch-core: the data folder is unavailable: \(error.localizedDescription)")
            exit(3)
        }
        guard helperLock != nil else {
            RPCServer.standardError("switch-core: another Switch helper already runs for \(paths.applicationSupport.path).")
            exit(3)
        }
        let log = try? HelperLog(url: HelperLog.location(paths: paths, environment: environment))
        let output = protocolOutput()
        let manager: AccountManager?
        do {
            manager = try AppEngine.makeManager(paths: paths)
        } catch {
            RPCServer.standardError("switch-core: the data folder is unavailable: \(error.localizedDescription)")
            manager = nil
        }
        let server = RPCServer(manager: manager, paths: paths, version: AIManagerBuildInfo.version) { line in
            RPCServer.standardError(line)
            log?.write(line)
        }
        let termination = onTerminate { await server.terminate() }
        await server.serve(input: .standardInput) { output.write($0) }
        withExtendedLifetime((helperLock, termination)) {}
        exit(0)
    }

    /// SIGTERM runs `stop`, then exits 0. Windows has no SIGTERM; the GUI closes stdin instead.
    private static func onTerminate(_ stop: @escaping @Sendable () async -> Void) -> Any? {
        #if os(Windows)
        return nil
        #else
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler {
            Task {
                await stop()
                exit(0)
            }
        }
        source.resume()
        return source
        #endif
    }

    /// Frames go to a private copy of stdout, and fd 1 then points at stderr, so a stray print or a child
    /// process that inherits stdout cannot write into the protocol stream.
    private static func protocolOutput() -> FileHandle {
        #if os(Windows)
        // shortcut: stdout is not moved on Windows yet, so an inheriting child could write into the stream;
        // move it with SetStdHandle when the Windows helper is packaged (plan unit K1).
        return .standardOutput
        #else
        let copy = dup(STDOUT_FILENO)
        guard copy >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { return .standardOutput }
        return FileHandle(fileDescriptor: copy, closeOnDealloc: true)
        #endif
    }
}
