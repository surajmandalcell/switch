import Foundation
import AIManagerCore

/// `logs/helper.log` (architecture.md 2.8): one line per request with method, id, time, and outcome; never params,
/// replies, or secrets. At most two files of 5 MiB (`helper.log`, then `helper.log.1`, the oldest dropped first);
/// lines older than 14 days are dropped when the helper starts.
public final class HelperLog: @unchecked Sendable {
    public static let maximumBytes = 5 * 1024 * 1024
    public static let maximumAge: TimeInterval = 14 * 86_400

    let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0

    public init(url: URL, now: Date = Date()) throws {
        self.url = url
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let cutoff = now.addingTimeInterval(-Self.maximumAge)
        let older = rotated
        if let modified = (try? manager.attributesOfItem(atPath: older.path))?[.modificationDate] as? Date, modified < cutoff {
            try manager.removeItem(at: older)
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            // Each line starts with its ISO 8601 UTC time, so a text compare orders them.
            let stamp = Self.stamp(cutoff)
            let kept = text.split(separator: "\n").filter { $0.prefix(stamp.count) >= stamp }
            try (kept.map { $0 + "\n" }.joined()).write(to: url, atomically: true, encoding: .utf8)
        } else {
            manager.createFile(atPath: url.path, contents: nil)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        size = ((try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size > Self.maximumBytes { try rotate() }
        handle = try FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    var rotated: URL { url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".1") }

    public func write(_ text: String, now: Date = Date()) {
        let line = Data("\(Self.stamp(now)) \(text)\n".utf8)
        lock.lock()
        defer { lock.unlock() }
        if size + line.count > Self.maximumBytes {
            try? handle?.close()
            handle = nil
            try? rotate()
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            handle = try? FileHandle(forWritingTo: url)
        }
        handle?.write(line)
        size += line.count
    }

    private func rotate() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: rotated.path) { try manager.removeItem(at: rotated) }
        try manager.moveItem(at: url, to: rotated)
        size = 0
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// `<data>/logs/helper.log` under `--root` and on macOS; `$XDG_STATE_HOME/switch/logs` on Linux (default
    /// `~/.local/state`); `%LOCALAPPDATA%\Switch\logs` on Windows (architecture.md section 5).
    public static func location(paths: ManagerPaths, environment: [String: String]) -> URL {
        if paths.isolationRoot != nil { return paths.applicationSupport.appending(path: "logs/helper.log") }
        #if os(Windows)
        let base = environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) }
            ?? paths.userHome.appending(path: "AppData/Local")
        return base.appending(path: "Switch/logs/helper.log")
        #elseif os(Linux)
        let base = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? paths.userHome.appending(path: ".local/state")
        return base.appending(path: "switch/logs/helper.log")
        #else
        return paths.applicationSupport.appending(path: "logs/helper.log")
        #endif
    }
}
