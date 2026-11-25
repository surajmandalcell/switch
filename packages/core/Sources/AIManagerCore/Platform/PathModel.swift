import Foundation
#if os(Windows)
import WinSDK
#endif

func normalizedPathSeparators(_ path: String) -> String {
#if os(Windows)
    path.replacingOccurrences(of: "\\", with: "/")
#else
    path
#endif
}

func equalPathNames(_ lhs: String, _ rhs: String) -> Bool {
#if os(Windows)
    lhs.withCString(encodedAs: UTF16.self) { left in
        rhs.withCString(encodedAs: UTF16.self) { right in
            CompareStringOrdinal(left, Int32(lhs.utf16.count), right, Int32(rhs.utf16.count), true) == CSTR_EQUAL
        }
    }
#else
    lhs == rhs
#endif
}

func backupPathKey(_ path: String) -> String {
#if os(Windows)
    path.uppercased()
#else
    path
#endif
}

func isSafeRelativeComponent(_ part: Substring) -> Bool {
    guard !part.isEmpty, part != ".", part != ".." else { return false }
#if os(Windows)
    // Win32 strips trailing dots/spaces and interprets colons as drive or stream names.
    guard !part.contains(":"), part.last != ".", part.last != " " else { return false }
    let device = part.prefix { $0 != "." }.uppercased()
    if ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(device) { return false }
    if device.count == 4, device.hasPrefix("COM") || device.hasPrefix("LPT"),
       let digit = device.last, "0123456789¹²³".contains(digit) { return false }
#endif
    return true
}

/// True for a path that does not depend on the working folder (plan unit P8).
/// Windows: a drive form (`C:\`, `C:/`), a UNC form (`\\server`, `//server`), or a rooted `\` or `/` path.
/// Elsewhere: a leading `/`.
func isAbsolutePath(_ path: String) -> Bool {
#if os(Windows)
    let bytes = Array(path.utf8.prefix(3))
    func separator(_ byte: UInt8) -> Bool { byte == UInt8(ascii: "/") || byte == UInt8(ascii: "\\") }
    if let first = bytes.first, separator(first) { return true }
    return bytes.count == 3 && Character(UnicodeScalar(bytes[0])).isLetter && bytes[1] == UInt8(ascii: ":") && separator(bytes[2])
#else
    return path.hasPrefix("/")
#endif
}

/// Where a command named `name` can live, for each folder in the environment's `PATH`, in search order.
/// Windows splits on `;` and tries `name` with each PATHEXT extension (.exe, .cmd, ...) after the bare name.
func executableCandidates(named name: String, environment: [String: String]) -> [URL] {
#if os(Windows)
    // Windows names the variable "Path"; environment keys keep their case.
    let path = environment.first { $0.key.uppercased() == "PATH" }?.value
    let extensions = (environment.first { $0.key.uppercased() == "PATHEXT" }?.value ?? ".COM;.EXE;.BAT;.CMD")
        .split(separator: ";").map { $0.lowercased() }
    return (path ?? "").split(separator: ";").flatMap { folder -> [URL] in
        let directory = URL(fileURLWithPath: String(folder))
        return [directory.appending(path: name)] + extensions.map { directory.appending(path: name + $0) }
    }
#else
    return (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appending(path: name) }
#endif
}

extension FileManager.DirectoryEnumerator {
    /// Does not descend into the link just returned. On Windows Foundation never descends into a link (reparse
    /// point), and its `skipDescendants` stops all descent for the rest of the walk, so there it does nothing.
    func skipLinkDescendants() {
#if !os(Windows)
        skipDescendants()
#endif
    }
}

enum Links {
    /// Creates a symbolic link at `link` that points to the absolute `target`.
    /// Windows: Foundation reads "C:/..." as a relative target and joins it under the link's folder, so the link is
    /// made with `CreateSymbolicLinkW` and native paths. Without Developer Mode or the symlink privilege it fails.
    static func create(at link: URL, to target: URL, fileManager: FileManager) throws {
#if os(Windows)
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory)
        let flags = DWORD(SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE) | (isDirectory.boolValue ? DWORD(SYMBOLIC_LINK_FLAG_DIRECTORY) : 0)
        let made = WindowsFiles.withWin32Path(WindowsFiles.native(link.path)) { from in
            WindowsFiles.withWin32Path(WindowsFiles.native(target.path)) { to in CreateSymbolicLinkW(from, to, flags) }
        }
        guard made != 0 else { throw WindowsFiles.lastError("Creating a symbolic link", link.path) }
#else
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
#endif
    }

    /// Makes `link` a second name (hard link) for the existing file `file`.
    /// Windows: Foundation's `linkItem` copies the file there, so this calls `CreateHardLinkW`.
    static func hardLink(at link: URL, to file: URL, fileManager: FileManager) throws {
#if os(Windows)
        let made = WindowsFiles.withWin32Path(WindowsFiles.native(link.path)) { to in
            WindowsFiles.withWin32Path(WindowsFiles.native(file.path)) { from in CreateHardLinkW(to, from, nil) }
        }
        guard made else { throw WindowsFiles.lastError("Creating a hard link", link.path) }
#else
        try fileManager.linkItem(at: file, to: link)
#endif
    }

    /// The link's target with "/" separators, so it compares equal to the `URL.path` or relative path it was made from.
    /// Windows reports "C:\..." (or "\\?\C:\..." for a long path) and "..\x".
    static func destination(of link: URL, fileManager: FileManager) throws -> String {
        let raw = try fileManager.destinationOfSymbolicLink(atPath: link.path)
#if os(Windows)
        return (raw.hasPrefix(#"\\?\"#) ? String(raw.dropFirst(4)) : raw).replacingOccurrences(of: "\\", with: "/")
#else
        return raw
#endif
    }
}
