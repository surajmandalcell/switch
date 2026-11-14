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

/// `switch-core serve [--root <path>]`: the helper the Linux and Windows apps start. It exits 0 when stdin closes.
/// `--root` means the same as `AI_MANAGER_ROOT`: every data folder and home lives under that path.
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
        let output = protocolOutput()
        let paths = ManagerPaths.environment(environment)
        let manager: AccountManager?
        do {
            manager = try AppEngine.makeManager(paths: paths)
        } catch {
            RPCServer.standardError("switch-core: the data folder is unavailable: \(error.localizedDescription)")
            manager = nil
        }
        let server = RPCServer(manager: manager, paths: paths, version: AIManagerBuildInfo.version)
        await server.serve(input: .standardInput) { output.write($0) }
        exit(0)
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
