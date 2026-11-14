import Foundation

/// Opens the user's terminal emulator on a launch script (plan unit P10). The command and its values live only in
/// the script, each value single-quoted, so an account name or a path never reaches a shell unquoted, and the
/// emulator gets one argument: the script path.
/// Linux: `xdg-terminal-exec`, then `$TERMINAL`, `x-terminal-emulator`, gnome-terminal, konsole, kitty, alacritty, xterm.
public enum TerminalLaunch {
    public enum Failure: Error, Equatable {
        case noEmulator
        case unsupported
    }

    /// The API-key variables a launch script unsets, so a key in the helper's environment never wins over the saved sign-in.
    static let unsetKeys = [
        "FACTORY_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "XAI_API_KEY", "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_AWS_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_ANTHROPIC_AWS",
    ]

    /// POSIX single quotes: `it's` becomes `'it'\''s'`.
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The `/bin/sh` script: unset the keys, export `exports` (sorted by name), change folder, exec the command.
    /// Export names that are not shell names are dropped.
    public static func script(command: [String], exports: [String: String], workingDirectory: String?) -> String {
        let names = exports.keys.filter { name in
            name.first.map { $0 == "_" || $0.isASCII && $0.isLetter } == true
                && name.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
        }.sorted()
        return (["#!/bin/sh", "set -e", "unset " + unsetKeys.joined(separator: " ")]
            + names.map { "export \($0)=\(quote(exports[$0]!))" }
            + (workingDirectory.map { ["cd \(quote($0))"] } ?? [])
            + ["exec " + command.map(quote).joined(separator: " ")]).joined(separator: "\n") + "\n"
    }

    /// The emulator command that runs `script`, from the first emulator found on `environment`'s PATH.
    public static func emulatorCommand(script: URL, environment: [String: String]) throws -> [String] {
#if os(Linux)
        func find(_ name: String) -> String? {
            if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
            return executableCandidates(named: name, environment: environment)
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
        }
        // Each emulator's own form for "run this program"; gnome-terminal takes it after `--`.
        let terminal = environment["TERMINAL"].flatMap { $0.isEmpty ? nil : ($0, ["-e"]) }
        let choices: [(String, [String])] = [("xdg-terminal-exec", [])] + (terminal.map { [$0] } ?? []) + [
            ("x-terminal-emulator", ["-e"]), ("gnome-terminal", ["--"]), ("konsole", ["-e"]), ("kitty", []),
            ("alacritty", ["-e"]), ("xterm", ["-e"]),
        ]
        for (name, flags) in choices {
            if let program = find(name) { return [program] + flags + [script.path] }
        }
        throw Failure.noEmulator
#else
        // windows-port: stub, plan unit P10 (`wt.exe -d <cwd>`, else `powershell.exe -NoExit`). macOS opens its
        // `.command` files in the Mac app, which the helper does not run.
        throw Failure.unsupported
#endif
    }

    /// Writes `contents` as an owner-only script at `file` and opens it in a terminal. `environment` is the
    /// helper's; the PATH in it finds the emulator.
    public static func launch(_ contents: String, at file: URL,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let command = try emulatorCommand(script: file, environment: environment)
        try write(contents, at: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// The script file alone, owner-only (an isolated run writes it and opens nothing).
    public static func write(_ contents: String, at file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try contents.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
}
