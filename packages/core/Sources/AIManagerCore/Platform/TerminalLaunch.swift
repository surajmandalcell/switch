import Foundation
#if os(Windows)
import WinSDK
#endif

/// Opens the user's terminal emulator on a launch script (plan unit P10). The command and its values live only in
/// the script, each value single-quoted, so an account name or a path never reaches a shell unquoted, and the
/// emulator gets one argument: the script path.
/// Linux: `xdg-terminal-exec`, then `$TERMINAL`, `x-terminal-emulator`, gnome-terminal, konsole, kitty, alacritty, xterm.
/// Windows: a `.cmd` script (see `cmdScript`) run by `cmd.exe /k`, in Windows Terminal (`wt.exe`) when present.
public enum TerminalLaunch {
    public enum Failure: Error, Equatable {
        case noEmulator
        /// The terminal chosen in Settings is not installed.
        case missing(String)
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

    /// The launch script for this system: `cmdScript` on Windows (a refusing script when a value cannot be quoted
    /// for cmd), else `shScript`.
    public static func script(command: [String], exports: [String: String], workingDirectory: String?) -> String {
#if os(Windows)
        cmdScript(command: command, exports: exports, workingDirectory: workingDirectory) ?? refusedCmdScript
#else
        shScript(command: command, exports: exports, workingDirectory: workingDirectory)
#endif
    }

    /// Export names that are shell and cmd variable names; others are dropped.
    private static func names(_ exports: [String: String]) -> [String] {
        exports.keys.filter { name in
            name.first.map { $0 == "_" || $0.isASCII && $0.isLetter } == true
                && name.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
        }.sorted()
    }

    /// The `/bin/sh` script: unset the keys, export `exports` (sorted by name), change folder, exec the command.
    static func shScript(command: [String], exports: [String: String], workingDirectory: String?) -> String {
        (["#!/bin/sh", "set -e", "unset " + unsetKeys.joined(separator: " ")]
            + names(exports).map { "export \($0)=\(quote(exports[$0]!))" }
            + (workingDirectory.map { ["cd \(quote($0))"] } ?? [])
            + ["exec " + command.map(quote).joined(separator: " ")]).joined(separator: "\n") + "\n"
    }

    /// The Windows `.cmd` script, same steps as `shScript`. Every value sits inside double quotes with `%` doubled,
    /// and delayed expansion is off, so `& | < > ^ !` stay literal. cmd has no way to quote `"`, a line break or NUL
    /// inside a value, so any such value gives nil and nothing is launched.
    static func cmdScript(command: [String], exports: [String: String], workingDirectory: String?) -> String? {
        let names = names(exports)
        let values = command + names.map { exports[$0]! } + (workingDirectory.map { [$0] } ?? [])
        guard !command.isEmpty, !values.contains(where: { $0.contains { "\"\r\n\0".contains($0) } }) else { return nil }
        func value(_ text: String) -> String { text.replacingOccurrences(of: "%", with: "%%") }
        // The program splits its own command line: backslashes before the closing quote must be doubled.
        func argument(_ text: String) -> String {
            "\"" + value(text) + String(repeating: "\\", count: text.reversed().prefix { $0 == "\\" }.count) + "\""
        }
        return (["@echo off", "chcp 65001 >nul", "setlocal DisableDelayedExpansion"]
            + unsetKeys.map { "set \"\($0)=\"" }
            + names.map { "set \"\($0)=\(value(exports[$0]!))\"" }
            + (workingDirectory.map { ["cd /d \"\(value($0))\" || exit /b 1"] } ?? [])
            + [command.map(argument).joined(separator: " ")]).joined(separator: "\r\n") + "\r\n"
    }

    static let refusedCmdScript = "@echo off\r\necho Switch did not start this: a value holds a double quote or a "
        + "line break, which cmd cannot quote safely.\r\nexit /b 1\r\n"

    /// One Windows command line from `arguments`, quoted the way programs split it back (CommandLineToArgvW).
    static func windowsCommandLine(_ arguments: [String]) -> String {
        arguments.map { argument in
            guard argument.isEmpty || argument.contains(where: { " \t\"".contains($0) }) else { return argument }
            var result = "\""
            var slashes = 0
            for character in argument {
                if character == "\\" { slashes += 1; continue }
                result += String(repeating: "\\", count: character == "\"" ? slashes * 2 + 1 : slashes) + String(character)
                slashes = 0
            }
            return result + String(repeating: "\\", count: slashes * 2) + "\""
        }.joined(separator: " ")
    }

    /// True when cmd reads `path` after `/k` as one plain file name: none of its special or separator characters.
    static func isPlainForCmd(_ path: String) -> Bool {
        !path.contains { "\"%!^&|<>()@,;=".contains($0) || $0.asciiValue.map { $0 < 32 } == true }
    }

    /// The launch file's real name: Windows picks the interpreter by extension, so `.sh` becomes `.cmd` there.
    static func scriptFile(_ file: URL) -> URL {
#if os(Windows)
        file.deletingPathExtension().appendingPathExtension("cmd")
#else
        file
#endif
    }

    /// The emulators tried in order, each with its own form for "run this program" (gnome-terminal takes it after
    /// `--`). Settings shows these names.
    /// Windows: Windows Terminal opens a new window that runs cmd on the script; cmd alone gets a new console.
#if os(Windows)
    public static let emulators: [(name: String, flags: [String])] = [("wt", ["-w", "new"]), ("cmd", [])]
#else
    public static let emulators: [(name: String, flags: [String])] = [
        ("xdg-terminal-exec", []), ("x-terminal-emulator", ["-e"]), ("gnome-terminal", ["--"]), ("konsole", ["-e"]),
        ("kitty", []), ("alacritty", ["-e"]), ("xterm", ["-e"]),
    ]
#endif

    /// The emulator command that runs `script`. `preferred` (the `terminalEmulator` setting: a name or a path) wins
    /// and is never replaced by another one; otherwise the first emulator found on `environment`'s PATH.
    public static func emulatorCommand(script: URL, environment: [String: String], preferred: String? = nil) throws -> [String] {
#if os(Linux)
        func find(_ name: String) -> String? {
            if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
            return executableCandidates(named: name, environment: environment)
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
        }
        func flags(_ name: String) -> [String] {
            emulators.first { $0.name == (name as NSString).lastPathComponent }?.flags ?? ["-e"]
        }
        if let preferred, !preferred.isEmpty {
            guard let program = find(preferred) else { throw Failure.missing(preferred) }
            return [program] + flags(preferred) + [script.path]
        }
        var choices = emulators
        if let terminal = environment["TERMINAL"], !terminal.isEmpty { choices.insert((terminal, flags(terminal)), at: 1) }
        for (name, flags) in choices {
            if let program = find(name) { return [program] + flags + [script.path] }
        }
        throw Failure.noEmulator
#elseif os(Windows)
        let path = WindowsFiles.native(script.path)
        // A script path cmd would split or expand is refused, not quoted around (cmd has no full quoting).
        guard isPlainForCmd(path) else { throw Failure.unsupported }
        let shell = environment.first { $0.key.uppercased() == "COMSPEC" }?.value ?? #"C:\Windows\System32\cmd.exe"#
        let cmd = [shell, "/d", "/k", path]
        func find(_ name: String) -> String? {
            if name.contains("\\") || name.contains("/") { return FileManager.default.fileExists(atPath: name) ? name : nil }
            return executableCandidates(named: name, environment: environment)
                .first { FileManager.default.fileExists(atPath: $0.path) }.map { WindowsFiles.native($0.path) }
        }
        func command(_ program: String) -> [String] {
            switch URL(fileURLWithPath: program).deletingPathExtension().lastPathComponent.lowercased() {
            case "wt": [program, "-w", "new"] + cmd
            case "cmd": [program] + cmd.dropFirst()
            default: [program, path]
            }
        }
        if let preferred, !preferred.isEmpty {
            guard let program = find(preferred) else { throw Failure.missing(preferred) }
            return command(program)
        }
        return find("wt").map(command) ?? cmd
#else
        // macOS opens its `.command` files in the Mac app, which the helper does not run.
        throw Failure.unsupported
#endif
    }

    /// Writes `contents` as an owner-only script at `file` and opens it in a terminal. `environment` is the
    /// helper's; the PATH in it finds the emulator.
    public static func launch(_ contents: String, at file: URL, preferred: String? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let file = scriptFile(file)
        let command = try emulatorCommand(script: file, environment: environment, preferred: preferred)
        try write(contents, at: file)
#if os(Windows)
        try openConsole(command)
#else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
#endif
    }

#if os(Windows)
    /// Starts `command` in a new console window; Foundation's Process gives a child no console of its own, so cmd
    /// would share the helper's hidden one.
    private static func openConsole(_ command: [String]) throws {
        var line = Array(windowsCommandLine(command).utf16) + [0]
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var info = PROCESS_INFORMATION()
        let started = line.withUnsafeMutableBufferPointer {
            CreateProcessW(nil, $0.baseAddress, nil, nil, false, DWORD(CREATE_NEW_CONSOLE), nil, nil, &startup, &info)
        }
        guard started else { throw WindowsFiles.lastError("Opening a terminal", command[0]) }
        CloseHandle(info.hThread)
        CloseHandle(info.hProcess)
    }
#endif

    /// The script file alone, owner-only (an isolated run writes it and opens nothing). Windows: `.cmd` (see
    /// `scriptFile`), through `PrivateFiles`.
    public static func write(_ contents: String, at file: URL) throws {
#if os(Windows)
        try PrivateFiles.write(Data(contents.utf8), to: scriptFile(file))
#else
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try contents.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
#endif
    }
}
