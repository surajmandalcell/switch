import Foundation
import XCTest
@testable import AIManagerCore

/// Plan unit P10. Writes scripts and fake emulators in a temporary folder; it never opens a terminal.
final class PlatformTerminalLaunchTests: XCTestCase {
    func testScriptQuotesEveryValueAndUnsetsKeys() throws {
        let hostile = "Work'; rm -rf ~; echo '$(id)`x`"
        let script = TerminalLaunch.shScript(
            command: ["/opt/my tools/droid", "--name", hostile],
            exports: ["HOME": "/tmp/a b", "FACTORY_HOME_OVERRIDE": "/tmp/it's", "BAD NAME": "x", "1X": "y"],
            workingDirectory: "/tmp/$HOME")
        XCTAssertEqual(script, """
            #!/bin/sh
            set -e
            unset \(TerminalLaunch.unsetKeys.joined(separator: " "))
            export FACTORY_HOME_OVERRIDE='/tmp/it'\\''s'
            export HOME='/tmp/a b'
            cd '/tmp/$HOME'
            exec '/opt/my tools/droid' '--name' 'Work'\\''; rm -rf ~; echo '\\''$(id)`x`'

            """)
        XCTAssertEqual(TerminalLaunch.unsetKeys.count, 13)

#if !os(Windows)
        // The shell reads the hostile value back as one argument, unchanged.
        let folder = FileManager.default.temporaryDirectory.appending(path: "terminal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "echo.sh")
        try TerminalLaunch.write(TerminalLaunch.script(command: ["/usr/bin/printf", "%s", hostile], exports: [:],
                                                       workingDirectory: nil), at: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
        let process = Process()
        process.executableURL = file
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), hostile)
#endif
    }

    func testEmulatorSelection() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = URL(fileURLWithPath: "/tmp/sign in.sh")
        let environment = ["PATH": folder.path]
        func add(_ name: String) throws {
            let file = folder.appending(path: name)
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        func command(_ extra: [String: String] = [:]) throws -> [String] {
            try TerminalLaunch.emulatorCommand(script: script, environment: environment.merging(extra) { $1 })
        }
#if os(Linux)
        XCTAssertThrowsError(try command()) { XCTAssertEqual($0 as? TerminalLaunch.Failure, .noEmulator) }
        // A file that is not executable does not count.
        try "".write(to: folder.appending(path: "xterm"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try command())
        try add("xterm")
        XCTAssertEqual(try command(), [folder.appending(path: "xterm").path, "-e", script.path])
        try add("gnome-terminal")
        XCTAssertEqual(try command(), [folder.appending(path: "gnome-terminal").path, "--", script.path])
        try add("kitty")
        try add("x-terminal-emulator")
        XCTAssertEqual(try command(), [folder.appending(path: "x-terminal-emulator").path, "-e", script.path])
        try add("foot")
        XCTAssertEqual(try command(["TERMINAL": "foot"]), [folder.appending(path: "foot").path, "-e", script.path])
        XCTAssertEqual(try command(["TERMINAL": "missing"]).first, folder.appending(path: "x-terminal-emulator").path)
        try add("xdg-terminal-exec")
        XCTAssertEqual(try command(["TERMINAL": "foot"]), [folder.appending(path: "xdg-terminal-exec").path, script.path])
        // The Settings choice wins, keeps its own flags, and is never swapped for another terminal.
        XCTAssertEqual(try TerminalLaunch.emulatorCommand(script: script, environment: environment, preferred: "kitty"),
                       [folder.appending(path: "kitty").path, script.path])
        XCTAssertEqual(try TerminalLaunch.emulatorCommand(script: script, environment: environment, preferred: "foot"),
                       [folder.appending(path: "foot").path, "-e", script.path])
        XCTAssertThrowsError(try TerminalLaunch.emulatorCommand(script: script, environment: environment, preferred: "wezterm")) {
            XCTAssertEqual($0 as? TerminalLaunch.Failure, .missing("wezterm"))
        }
#elseif os(Windows)
        let path = WindowsFiles.native(script.path)
        XCTAssertEqual(try command(), [#"C:\Windows\System32\cmd.exe"#, "/d", "/k", path])
        XCTAssertEqual(try command(["ComSpec": #"D:\cmd.exe"#]).first, #"D:\cmd.exe"#)
        try add("wt.exe")
        let wt = WindowsFiles.native(folder.appending(path: "wt.exe").path)
        XCTAssertEqual(try command(), [wt, "-w", "new", #"C:\Windows\System32\cmd.exe"#, "/d", "/k", path])
        XCTAssertThrowsError(try TerminalLaunch.emulatorCommand(script: script, environment: environment, preferred: "wezterm")) {
            XCTAssertEqual($0 as? TerminalLaunch.Failure, .missing("wezterm"))
        }
        // A script path cmd would split or expand is refused.
        XCTAssertThrowsError(try TerminalLaunch.emulatorCommand(script: URL(fileURLWithPath: #"C:\a&b\x.cmd"#),
                                                               environment: environment)) {
            XCTAssertEqual($0 as? TerminalLaunch.Failure, .unsupported)
        }
        XCTAssertEqual(TerminalLaunch.scriptFile(URL(fileURLWithPath: #"C:\x\sign-in.sh"#)).lastPathComponent, "sign-in.cmd")
#else
        try add("xterm")
        XCTAssertThrowsError(try command()) { XCTAssertEqual($0 as? TerminalLaunch.Failure, .unsupported) }
#endif
    }

    /// The Windows script and command line, checked as text on every platform.
    func testCmdScriptQuotesHostileValuesAndRefusesUnquotable() {
        let hostile = "Work & calc | x > y ^ %PATH% !x! (a)"
        let script = TerminalLaunch.cmdScript(
            command: [#"C:\my tools\droid.exe"#, "--name", hostile, #"C:\dir\"#],
            exports: ["HOME": #"C:\Users\a b"#, "FACTORY_HOME_OVERRIDE": "100%", "BAD NAME": "x\"y"],
            workingDirectory: #"C:\work %TEMP%"#)
        let expected = ["@echo off", "chcp 65001 >nul", "setlocal DisableDelayedExpansion"]
            + TerminalLaunch.unsetKeys.map { "set \"\($0)=\"" }
            + [#"set "FACTORY_HOME_OVERRIDE=100%%""#, #"set "HOME=C:\Users\a b""#, #"cd /d "C:\work %%TEMP%%" || exit /b 1"#,
               #""C:\my tools\droid.exe" "--name" "Work & calc | x > y ^ %%PATH%% !x! (a)" "C:\dir\\""#]
        XCTAssertEqual(script, expected.joined(separator: "\r\n") + "\r\n")

        // A double quote or a line break cannot be quoted for cmd: nothing is built.
        XCTAssertNil(TerminalLaunch.cmdScript(command: ["droid", "a\"&calc"], exports: [:], workingDirectory: nil))
        XCTAssertNil(TerminalLaunch.cmdScript(command: ["droid"], exports: ["HOME": "x\r\ncalc"], workingDirectory: nil))
        XCTAssertNil(TerminalLaunch.cmdScript(command: ["droid"], exports: [:], workingDirectory: "C:\\\"x"))
        XCTAssertNil(TerminalLaunch.cmdScript(command: [], exports: [:], workingDirectory: nil))
        XCTAssertTrue(TerminalLaunch.refusedCmdScript.hasSuffix("exit /b 1\r\n"))

        XCTAssertEqual(TerminalLaunch.windowsCommandLine([#"C:\a b\wt.exe"#, "-w", "new", "", "x\"y", #"C:\dir\"#, #"C:\d ir\"#]),
                       #""C:\a b\wt.exe" -w new "" "x\"y" C:\dir\ "C:\d ir\\""#)
        XCTAssertTrue(TerminalLaunch.isPlainForCmd(#"C:\Users\a b\Switch\Launch\sign-in.cmd"#))
        for unsafe in [#"C:\a&b\x.cmd"#, #"C:\100%\x.cmd"#, "C:\\a;b\\x.cmd", "C:\\a\"b", "C:\\(x)\\y", "C:\\a\nb"] {
            XCTAssertFalse(TerminalLaunch.isPlainForCmd(unsafe), unsafe)
        }
    }
}
