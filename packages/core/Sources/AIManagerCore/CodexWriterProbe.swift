import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Uses Codex's lifetime arg0 lock, never process environments or credential contents.
enum CodexWriterProbe {
    static func check(home: URL) -> WriterState {
        do {
            let (status, data) = try output("/usr/bin/pgrep", ["-x", "codex"])
            if status == 1, data.isEmpty { return .inactive }
            guard status == 0, let text = String(data: data, encoding: .utf8) else { return .unknown }
            let tokens = text.split(whereSeparator: \.isWhitespace)
            let pids = tokens.compactMap { Int32($0) }.filter { $0 > 0 }
            guard !pids.isEmpty, pids.count == tokens.count else { return .unknown }
            return check(home: home, pids: pids)
        } catch { return .unknown }
    }

    static func check(home: URL, pids: [Int32]) -> WriterState {
        var unknown = false
        for pid in pids {
            do {
                let paths = try openPaths(pid: pid)
                if paths.contains(where: {
                    CoreSupport.isContained($0, by: home)
                        || CoreSupport.isContained($0, by: home.appending(path: "tmp/arg0"))
                }) { return .active }
                let homes = try paths.compactMap { try lockedHome($0) }
                if homes.isEmpty {
                    if kill(pid, 0) == 0 || errno != ESRCH { unknown = true }
                    continue
                }
                for writerHome in homes {
                    if CoreSupport.isContained(writerHome, by: home)
                        || CoreSupport.isContained(home, by: writerHome) { return .active }
                    // A separate home can still write linked shared settings or history.
                    for entry in CoreSupport.settings + CoreSupport.sharedHistoryEntries {
                        let target = writerHome.appending(path: entry)
                        if CoreSupport.entryExists(target),
                           CoreSupport.isContained(target, by: home)
                            || CoreSupport.isContained(home, by: target) { return .active }
                    }
                }
            } catch {
                if kill(pid, 0) == 0 || errno != ESRCH { unknown = true }
            }
        }
        return unknown ? .unknown : .inactive
    }

    private static func lockedHome(_ path: URL) throws -> URL? {
        let directory = path.deletingLastPathComponent()
        let arg0 = directory.deletingLastPathComponent()
        let tmp = arg0.deletingLastPathComponent()
        guard path.lastPathComponent == ".lock", directory.lastPathComponent.hasPrefix("codex-arg0"),
              arg0.lastPathComponent == "arg0", tmp.lastPathComponent == "tmp" else { return nil }
        let descriptor = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw probeError() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw probeError() }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return nil
        }
        guard errno == EWOULDBLOCK || errno == EAGAIN else { throw probeError() }
        return tmp.deletingLastPathComponent()
    }

    private static func openPaths(pid: Int32) throws -> [URL] {
#if canImport(Darwin)
        let (status, data) = try output("/usr/sbin/lsof", ["-n", "-P", "-a", "-p", String(pid), "-F0n"])
        guard status == 0 else { throw probeError() }
        return data.split(separator: 0).compactMap { field in
            guard field.first == 110, let path = String(data: field.dropFirst(), encoding: .utf8),
                  path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        }
#else
        let root = URL(fileURLWithPath: "/proc/\(pid)/fd")
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { entry in
                do {
                    let path = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
                    guard path.hasPrefix("/"), !path.hasSuffix(" (deleted)") else { return nil }
                    return URL(fileURLWithPath: path)
                } catch {
                    // Descriptors may close during enumeration. Permission failures are unknown.
                    var info = stat()
                    if lstat(entry.path, &info) != 0, errno == ENOENT { return nil }
                    throw error
                }
            }
#endif
    }

    private static func output(_ executable: String, _ arguments: [String]) throws -> (Int32, Data) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                guard data.count + chunk.count <= 4 * 1_024 * 1_024 else { throw probeError() }
                data.append(chunk)
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private static func probeError() -> AIManagerError {
        .writerStateUnknown
    }
}
