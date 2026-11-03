import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct DroidSessionBindingReport: Codable, Equatable, Sendable {
    public var updatedCount: Int
    public var unchangedCount: Int
    public var skippedCount: Int
    public var failedCount: Int
    public var warnings: [String]

    public init(updatedCount: Int = 0, unchangedCount: Int = 0, skippedCount: Int = 0, failedCount: Int = 0, warnings: [String] = []) {
        self.updatedCount = updatedCount; self.unchangedCount = unchangedCount
        self.skippedCount = skippedCount; self.failedCount = failedCount; self.warnings = warnings
    }
}

enum DroidSessionBinding {
    private static let fm = FileManager.default
    private static let headerLimit = 1_048_576

    private struct Header {
        let bytes: Data
        let id: String
        let object: [String: Any]
        let organization: String
        let valueRange: Range<Int>
    }

    private struct Candidate {
        let url: URL
        let id: String
        let headerDigest: String
        let parents: [String]
        let mission: Bool
    }

    private struct Pending: Codable {
        let path: String
        let temporary: String
        let originalHeader: Data
        let newHeader: Data
        let originalDigest: String
        var updatedDigest: String?
        let modified: Date
        let permissions: Int
        let createdDate: Date?
    }

    private enum Failure: LocalizedError {
        case unsafe, malformed, changed, probe, recoveryConflict, headerTooLarge
        var errorDescription: String? {
            switch self {
            case .unsafe: "An unsafe session path was skipped."
            case .malformed: "A session header is invalid or ambiguous; its transcript was preserved."
            case .changed: "A session changed during the switch; retry after Droid stops."
            case .probe: "Droid did not create one safe empty session with a destination organization."
            case .recoveryConflict: "An interrupted session update has conflicting edits. Both files were preserved for recovery."
            case .headerTooLarge: "The destination organization would make this session header too large; the transcript was preserved."
            }
        }
    }

    static func rebind(
        home: URL, state: URL, initialize: (UUID, URL, String) throws -> Void,
        beforeWrite: () throws -> Void = {}
    ) throws -> DroidSessionBindingReport {
        try safe(home, within: home)
        let root = home.appending(path: "sessions")
        guard CoreSupport.entryExists(root) else { return .init() }
        try safe(root, within: root)
        try CoreSupport.privateDirectory(state, fileManager: fm)
        let lock = try OperationLock(at: state.appending(path: "lock"), fileManager: fm)
        return try lock.withLock {
            _ = try recover(root: root, state: state, beforeWrite: beforeWrite)
            var report = DroidSessionBindingReport()
            let files = try inventory(root: root, report: &report)
            var candidates: [Candidate] = []
            for url in files {
                do {
                    let header = try header(at: url, root: root)
                    candidates.append(.init(url: url, id: header.id,
                        headerDigest: CoreSupport.digest(header.bytes),
                        parents: ["parentSessionId", "callingSessionId"].compactMap { (header.object[$0] as? String)?.lowercased() },
                        mission: isMission(header.object, home: home)))
                } catch {
                    report.skippedCount += 1
                    report.warnings.append("Session \(url.deletingPathExtension().lastPathComponent): \(error.localizedDescription)")
                }
            }
            var missionIDs = Set(candidates.filter(\.mission).map(\.id))
            let missionFolders = (try? fm.contentsOfDirectory(at: home.appending(path: "missions"), includingPropertiesForKeys: nil)) ?? []
            missionIDs.formUnion(missionFolders.compactMap { UUID(uuidString: $0.lastPathComponent)?.uuidString.lowercased() })
            var previousCount: Int
            repeat {
                previousCount = missionIDs.count
                for candidate in candidates {
                    if candidate.parents.contains(where: missionIDs.contains) {
                        missionIDs.insert(candidate.id)
                    }
                }
            } while previousCount != missionIDs.count
            let beforeMissionFilter = candidates.count
            candidates.removeAll { candidate in
                if missionIDs.contains(candidate.id) {
                    report.skippedCount += 1
                    return true
                }
                return false
            }
            if beforeMissionFilter != candidates.count {
                report.warnings.append("\(beforeMissionFilter - candidates.count) mission sessions kept their original organization because cloud mission ownership cannot move between accounts.")
            }
            guard !candidates.isEmpty else { return report }
            let probe = UUID()
            let existingEntries = (fm.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
            let previousPaths = Set(existingEntries.map { root.appending(path: $0).path })
            do {
                try beforeWrite()
                try initialize(probe, home, "Switch organization check")
                var ignored = DroidSessionBindingReport()
                let probes = try inventory(root: root, report: &ignored).filter {
                    UUID(uuidString: $0.deletingPathExtension().lastPathComponent) == probe && !previousPaths.contains($0.path)
                }
                guard probes.count == 1 else { throw Failure.probe }
                let native = try header(at: probes[0], root: root)
                guard try emptyProbe(probes[0], header: native) else { throw Failure.probe }
                for candidate in candidates {
                    let url = candidate.url
                    do {
                        let snapshot = try header(at: url, root: root)
                        guard CoreSupport.digest(snapshot.bytes) == candidate.headerDigest else { throw Failure.changed }
                        if snapshot.organization == native.organization {
                            report.unchangedCount += 1
                            continue
                        }
                        try publish(url, header: snapshot, organization: native.organization,
                            root: root, state: state, beforeWrite: beforeWrite)
                        report.updatedCount += 1
                    } catch {
                        report.failedCount += 1
                        report.warnings.append("Session \(url.deletingPathExtension().lastPathComponent): \(error.localizedDescription)")
                        _ = try recover(root: root, state: state, beforeWrite: beforeWrite)
                    }
                }
            } catch {
                try cleanupProbe(probe, root: root, previousPaths: previousPaths, beforeWrite: beforeWrite)
                throw error
            }
            if report.skippedCount + report.failedCount > 0 {
                report.warnings.append("\(report.skippedCount) sessions were skipped and \(report.failedCount) failed; review the reported reasons before resuming them.")
            }
            do { try cleanupProbe(probe, root: root, previousPaths: previousPaths, beforeWrite: beforeWrite) }
            catch { report.warnings.append("The native check session was preserved: \(error.localizedDescription)") }
            return report
        }
    }

    private static func inventory(root: URL, report: inout DroidSessionBindingReport) throws -> [URL] {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { throw Failure.unsafe }
        var files: [URL] = []
        for case let url as URL in walker {
            let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if attributes.isSymbolicLink == true {
                report.skippedCount += 1
                report.warnings.append("An unsafe session link was preserved.")
            } else if attributes.isRegularFile == true, url.pathExtension == "jsonl" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func header(at url: URL, root: URL) throws -> Header {
        try safe(url, within: root)
        let handle = try openRead(url)
        defer { try? handle.close() }
        var bytes = Data()
        while bytes.count <= headerLimit {
            let part = try handle.read(upToCount: 4096) ?? Data()
            guard !part.isEmpty else { throw Failure.malformed }
            if let newline = part.firstIndex(of: 10) {
                bytes.append(part.prefix(through: newline))
                break
            }
            bytes.append(part)
        }
        guard bytes.count <= headerLimit, bytes.last == 10,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["type"] as? String == "session_start",
              let id = object["id"] as? String, UUID(uuidString: id) != nil,
              UUID(uuidString: id) == UUID(uuidString: url.deletingPathExtension().lastPathComponent),
              let organization = object["organizationId"] as? String,
              !organization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.malformed }
        let range = try organizationRange(bytes)
        return Header(bytes: bytes, id: id.lowercased(), object: object, organization: organization, valueRange: range)
    }

    private static func organizationRange(_ data: Data) throws -> Range<Int> {
        let bytes = Array(data)
        var index = 0
        func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func stringEnd(_ start: Int) throws -> Int {
            guard start < bytes.count, bytes[start] == 34 else { throw Failure.malformed }
            var end = start + 1
            while end < bytes.count {
                if bytes[end] == 92 { end += 2; continue }
                if bytes[end] == 34 { return end + 1 }
                end += 1
            }
            throw Failure.malformed
        }
        whitespace()
        guard index < bytes.count, bytes[index] == 123 else { throw Failure.malformed }
        index += 1
        var keys = Set<String>(), result: Range<Int>?
        while index < bytes.count {
            whitespace()
            if bytes[index] == 125 { break }
            let keyStart = index, keyEnd = try stringEnd(index)
            let key = try JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<keyEnd]))
            guard keys.insert(key).inserted else { throw Failure.malformed }
            index = keyEnd; whitespace()
            guard index < bytes.count, bytes[index] == 58 else { throw Failure.malformed }
            index += 1; whitespace()
            let start = index
            if bytes[index] == 34 { index = try stringEnd(index) }
            else {
                var depth = 0
                while index < bytes.count {
                    let value = bytes[index]
                    if value == 34 { index = try stringEnd(index); continue }
                    if value == 123 || value == 91 { depth += 1 }
                    if value == 125 || value == 93 {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    if value == 44 && depth == 0 { break }
                    index += 1
                }
            }
            if key == "organizationId" {
                guard bytes[start] == 34 else { throw Failure.malformed }
                result = start..<index
            }
            whitespace()
            guard index < bytes.count else { throw Failure.malformed }
            if bytes[index] == 125 { break }
            guard bytes[index] == 44 else { throw Failure.malformed }
            index += 1
        }
        guard let result else { throw Failure.malformed }
        return result
    }

    private static func publish(
        _ url: URL, header snapshot: Header, organization: String, root: URL, state: URL,
        beforeWrite: () throws -> Void
    ) throws {
        let current = try header(at: url, root: root)
        guard current.bytes == snapshot.bytes else { throw Failure.changed }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let originalDigest = try digest(url)
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        var updatedHeader = snapshot.bytes
        updatedHeader.replaceSubrange(snapshot.valueRange, with: try JSONEncoder().encode(organization))
        guard updatedHeader.count <= headerLimit else { throw Failure.headerTooLarge }
        let temporary = url.deletingLastPathComponent().appending(path: ".switch-bind-\(UUID().uuidString).tmp")
        let relative = url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
        var journal = Pending(path: relative, temporary: temporary.lastPathComponent,
            originalHeader: snapshot.bytes, newHeader: updatedHeader, originalDigest: originalDigest,
            updatedDigest: nil, modified: modified, permissions: permissions,
            createdDate: attributes[.creationDate] as? Date)
        let journalURL = state.appending(path: "pending.json")
        try CoreSupport.atomicWrite(JSONEncoder().encode(journal), to: journalURL, fileManager: fm)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw Failure.unsafe }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let input = try openRead(url)
        defer { try? input.close(); try? output.close() }
        try output.write(contentsOf: updatedHeader)
        try input.seek(toOffset: UInt64(snapshot.bytes.count))
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
        journal.updatedDigest = try digest(temporary)
        try CoreSupport.atomicWrite(JSONEncoder().encode(journal), to: journalURL, fileManager: fm)
        try beforeWrite()
        try safe(url, within: root)
        guard try digest(url) == originalDigest else { throw Failure.changed }
        try CoreSupport.exchange(temporary, url)
        if try recover(root: root, state: state, beforeWrite: beforeWrite) == .restoredChangedOriginal {
            throw Failure.changed
        }
    }

    private enum RecoveryOutcome { case ready, restoredChangedOriginal }

    private static func recover(root: URL, state: URL, beforeWrite: () throws -> Void) throws -> RecoveryOutcome {
        let journalURL = state.appending(path: "pending.json")
        guard CoreSupport.entryExists(journalURL) else { return .ready }
        try safe(journalURL, within: state)
        let handle = try openRead(journalURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: headerLimit * 3 + 1) ?? Data()
        guard data.count <= headerLimit * 3 else { throw Failure.unsafe }
        let journal = try JSONDecoder().decode(Pending.self, from: data)
        guard CoreSupport.safeRelativePath(journal.path),
              journal.temporary.hasPrefix(".switch-bind-"), journal.temporary.hasSuffix(".tmp"),
              !journal.temporary.contains("/") else { throw Failure.unsafe }
        let target = root.appending(path: journal.path)
        try safe(target, within: root)
        let temporary = target.deletingLastPathComponent().appending(path: journal.temporary)
        let targetDigest = try digest(target)
        if CoreSupport.entryExists(temporary) {
            try safe(temporary, within: root)
            let temporaryDigest = try digest(temporary)
            if let updatedDigest = journal.updatedDigest,
               temporaryDigest != updatedDigest {
                guard targetDigest == updatedDigest else { throw Failure.recoveryConflict }
                if temporaryDigest != journal.originalDigest {
                    try beforeWrite()
                    guard try digest(target) == updatedDigest else { throw Failure.recoveryConflict }
                    try CoreSupport.exchange(temporary, target)
                    guard try digest(temporary) == updatedDigest else { throw Failure.recoveryConflict }
                    try beforeWrite()
                    guard unlink(temporary.path) == 0 else { throw Failure.unsafe }
                    try beforeWrite()
                    guard unlink(journalURL.path) == 0 else { throw Failure.unsafe }
                    return .restoredChangedOriginal
                }
            }
            // The stage contains either our unpublished output or the verified original inode.
            try beforeWrite()
            guard unlink(temporary.path) == 0 else { throw Failure.unsafe }
        }
        try beforeWrite()
        if journal.updatedDigest != nil, targetDigest == journal.updatedDigest {
            var attributes: [FileAttributeKey: Any] = [.modificationDate: journal.modified, .posixPermissions: journal.permissions]
            #if os(macOS)
            if let createdDate = journal.createdDate { attributes[.creationDate] = createdDate }
            #endif
            try fm.setAttributes(attributes, ofItemAtPath: target.path)
        }
        guard unlink(journalURL.path) == 0 else { throw Failure.unsafe }
        return .ready
    }

    private static func emptyProbe(_ url: URL, header: Header) throws -> Bool {
        let handle = try openRead(url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(header.bytes.count))
        var pending = Data()
        while let bytes = try handle.read(upToCount: 4096), !bytes.isEmpty {
            pending.append(bytes)
            guard pending.count <= headerLimit else { return false }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard !line.isEmpty, let event = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
                if let message = event["message"] as? [String: Any], ["user", "assistant"].contains(message["role"] as? String ?? "") { return false }
            }
        }
        return pending.isEmpty
    }

    private static func cleanupProbe(
        _ id: UUID, root: URL, previousPaths: Set<String>, beforeWrite: () throws -> Void
    ) throws {
        var ignored = DroidSessionBindingReport()
        let files = try inventory(root: root, report: &ignored)
        for url in files where UUID(uuidString: url.deletingPathExtension().lastPathComponent) == id && !previousPaths.contains(url.path) {
            guard let value = try? header(at: url, root: root), (try? emptyProbe(url, header: value)) == true else { continue }
            try beforeWrite()
            guard unlink(url.path) == 0 || errno == ENOENT else { throw Failure.unsafe }
            let settings = url.deletingPathExtension().appendingPathExtension("settings.json")
            if !previousPaths.contains(settings.path), CoreSupport.entryExists(settings),
               (try? safe(settings, within: root)) != nil {
                try beforeWrite()
                guard unlink(settings.path) == 0 || errno == ENOENT else { throw Failure.unsafe }
            }
            var directory = url.deletingLastPathComponent()
            while !CoreSupport.sameLocation(directory, root), !previousPaths.contains(directory.path) {
                try beforeWrite()
                guard rmdir(directory.path) == 0 else { break }
                directory.deleteLastPathComponent()
            }
        }
    }

    private static func isMission(_ object: [String: Any], home: URL) -> Bool {
        for key in ["missionId", "decompMissionId", "decompSessionType"] {
            if let value = object[key], !(value is NSNull), String(describing: value) != "" { return true }
        }
        func tagged(_ value: Any) -> Bool {
            if let text = value as? String { return ["mission", "mission-session"].contains(text) }
            if let object = value as? [String: Any] {
                if let name = object["name"], tagged(name) { return true }
                if let metadata = object["metadata"] as? [String: Any] { return metadata["missionId"] != nil || metadata["decompMissionId"] != nil }
            }
            if let array = value as? [Any] { return array.contains(where: tagged) }
            return false
        }
        if let tags = object["tags"], tagged(tags) { return true }
        return (object["id"] as? String).map { CoreSupport.entryExists(home.appending(path: "missions/\($0)")) } ?? false
    }

    private static func openRead(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AIManagerError.unsafePath("could not safely open session file \(url.path) (\(errno))") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid() else {
            close(descriptor)
            throw AIManagerError.unsafePath("session file ownership or link count is unsafe: \(url.path)")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try openRead(url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func safe(_ url: URL, within root: URL) throws {
        guard CoreSupport.isContained(url, by: root),
              CoreSupport.canonical(url).pathComponents == url.standardizedFileURL.pathComponents else {
            throw AIManagerError.unsafePath("session path does not match its resolved location: \(url.path)")
        }
        var current = url.standardizedFileURL
        let count = current.pathComponents.count - root.standardizedFileURL.pathComponents.count
        guard count >= 0 else { throw Failure.unsafe }
        for _ in 0...count {
            if CoreSupport.entryExists(current), (try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw AIManagerError.unsafePath("session path contains a symbolic link: \(current.path)")
            }
            current.deleteLastPathComponent()
        }
    }
}
