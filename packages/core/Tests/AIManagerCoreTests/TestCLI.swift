import Foundation

/// Fake command-line tools for tests.
enum TestCLI {
#if os(Windows)
    private static let shell = #"C:\Program Files\Git\bin\bash.exe"#
    /// A program that exits 0 at once; tests use it where any runnable CLI will do.
    static let trueExecutable = URL(fileURLWithPath: #"C:\Program Files\Git\usr\bin\true.exe"#)
    /// A PATH that holds `true` and the other basic tools.
    static let searchPath = #"C:\Program Files\Git\usr\bin"#
#else
    static let trueExecutable = URL(fileURLWithPath: "/usr/bin/true")
    static let searchPath = "/usr/bin:/bin"
#endif

    /// Writes `script` (a POSIX shell script with its `#!` line) as a runnable fake CLI at `url` and returns what to run.
    /// POSIX: `url` itself with the given mode. Windows: the script stays at `url` and a `<url>.cmd` beside it runs it
    /// with Git for Windows' bash; the `.cmd` is returned.
    @discardableResult
    static func write(_ script: String, to url: URL, permissions: Int = 0o755) throws -> URL {
        try Data(script.utf8).write(to: url)
#if os(Windows)
        let launcher = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".cmd")
        // Forward slashes, so `$0` and `dirname "$0"` work inside bash.
        let script = url.path.replacingOccurrences(of: "\\", with: "/")
        try Data("@\"\(shell)\" \"\(script)\" %*\r\n".utf8).write(to: launcher)
        return launcher
#else
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url
#endif
    }
}
