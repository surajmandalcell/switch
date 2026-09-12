import Foundation
import XCTest
@testable import AIManagerCore


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

final class RealCopyIntegrationTests: XCTestCase {
    func testAuthorizedPrivateCopyPlanningMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["AI_MANAGER_REAL_COPY_SOURCE"],
              let rootPath = environment["AI_MANAGER_REAL_COPY_ROOT"] else {
            throw XCTSkip("Set AI_MANAGER_REAL_COPY_SOURCE and AI_MANAGER_REAL_COPY_ROOT to an authorized private copy.")
        }
        let (source, root) = try validatedPaths(sourcePath: sourcePath, rootPath: rootPath)
        let telemetry = root.appending(path: "real-copy-plan-metrics.log")
        try Data().write(to: telemetry)
        let started = Date()
        Self.record("REAL_COPY_PLAN before elapsed_seconds=0 peak_rss_bytes=\(Self.peakRSS())", to: telemetry)
        let sampler = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                Self.record("REAL_COPY_PLAN progress elapsed_seconds=\(Int(Date().timeIntervalSince(started))) peak_rss_bytes=\(Self.peakRSS())", to: telemetry)
            }
        }
        defer { sampler.cancel() }
        let paths = ManagerPaths.environment(["AI_MANAGER_ROOT": root.path, "AI_MANAGER_CODEX_EXECUTABLE": "/usr/bin/true"])
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .full)
        let line = "REAL_COPY_PLAN result elapsed_seconds=\(Int(Date().timeIntervalSince(started))) peak_rss_bytes=\(Self.peakRSS()) manifest=\(plan.manifest.count) conflicts=\(plan.conflicts.count)"
        Self.record(line, to: telemetry)
        print(line)
        fflush(nil)
    }

    func testAuthorizedPrivateCopyFullImport() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["AI_MANAGER_REAL_COPY_SOURCE"],
              let rootPath = environment["AI_MANAGER_REAL_COPY_ROOT"] else {
            throw XCTSkip("Set AI_MANAGER_REAL_COPY_SOURCE and AI_MANAGER_REAL_COPY_ROOT to an authorized private copy.")
        }
        let (source, root) = try validatedPaths(sourcePath: sourcePath, rootPath: rootPath)
        let fileManager = FileManager.default
        let auth = source.appending(path: "auth.json")
        let authBefore = try hash(auth)
        let telemetry = root.appending(path: "real-copy-metrics.log")
        try Data().write(to: telemetry)
        let started = Date()
        Self.record("REAL_COPY_STAGE before_recovery elapsed_seconds=0 peak_rss_bytes=\(Self.peakRSS())", to: telemetry)
        let sampler = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                let line = "REAL_COPY_PROGRESS elapsed_seconds=\(Int(Date().timeIntervalSince(started))) peak_rss_bytes=\(Self.peakRSS())"
                Self.record(line, to: telemetry)
                print(line)
                fflush(nil)
            }
        }
        defer { sampler.cancel() }
        let paths = ManagerPaths.environment(["AI_MANAGER_ROOT": root.path, "AI_MANAGER_CODEX_EXECUTABLE": "/usr/bin/true"])
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let recovery = try await manager.recover()
        Self.record("REAL_COPY_STAGE after_recovery elapsed_seconds=\(Int(Date().timeIntervalSince(started))) peak_rss_bytes=\(Self.peakRSS())", to: telemetry)
        XCTAssertFalse(recovery.contains { $0.outcome == .conflict }, "An earlier interrupted validation run requires manual conflict review")
        if !recovery.isEmpty {
            let outcomes = Dictionary(grouping: recovery, by: \.outcome).mapValues(\.count)
            print("REAL_COPY_RECOVERY operations=\(recovery.count) outcomes=\(outcomes)")
            fflush(nil)
        }
        let plan = try await manager.planImport(source: source, mode: .full)
        Self.record("REAL_COPY_STAGE after_plan elapsed_seconds=\(Int(Date().timeIntervalSince(started))) peak_rss_bytes=\(Self.peakRSS())", to: telemetry)
        let decisions = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.relativePath, ConflictChoice.keepShared) })
        let result = try await manager.importAccount(plan: plan, decisions: decisions)
        Self.record("REAL_COPY_STAGE after_import elapsed_seconds=\(Int(Date().timeIntervalSince(started))) peak_rss_bytes=\(Self.peakRSS())", to: telemetry)

        let preserved = try transcriptCatalog(roots: [paths.sharedRoot, result.backup])
        var checked = 0
        var accounted = 0
        for directory in ["sessions", "archived_sessions"] {
            let sourceRoot = source.appending(path: directory)
            guard let enumerator = fileManager.enumerator(at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { continue }
            while let file = enumerator.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true, file.pathExtension == "jsonl" else { continue }
                checked += 1
                let sourceHash = try hash(file)
                if preserved.hashes.contains(sourceHash) {
                    accounted += 1
                } else if let identity = try identity(file),
                          try (preserved.byIdentity[identity] ?? []).contains(where: { try isRecordPrefix(file, of: $0) }) {
                    accounted += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
        XCTAssertEqual(accounted, checked, "Every source transcript must exist by exact hash, as a strict prefix of a preserved extension, or in the protected conflict backup.")
        XCTAssertEqual(try hash(auth), authBefore, "The private source credential changed during import")
        let categories = Dictionary(grouping: result.unresolved, by: unresolvedCategory).mapValues(\.count)
        let peakRSS = Self.peakRSS()
        print("REAL_COPY_RESULT source=\(checked) accounted=\(accounted) imported=\(result.importedChats) unresolved=\(categories.sorted { $0.key < $1.key }) peak_rss_bytes=\(peakRSS)")
    }

    nonisolated private static func peakRSS() -> Int {
        var usage = rusage()
#if os(Linux)
        return getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage) == 0
            ? usage.ru_maxrss * 1_024 : -1
#else
        return getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : -1
#endif
    }

    nonisolated private static func record(_ line: String, to url: URL) {
        guard let data = (line + "\n").data(using: .utf8), let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {}
    }

    private func contains(_ child: URL, in parent: URL) -> Bool {
        let childParts = child.pathComponents
        let parentParts = parent.pathComponents
        return childParts.count >= parentParts.count && Array(childParts.prefix(parentParts.count)) == parentParts
    }

    private func validatedPaths(sourcePath: String, rootPath: String) throws -> (URL, URL) {
        let allowed = CoreSupport.canonical(URL(fileURLWithPath: "/private/tmp/ai-manager-validation"))
        let source = CoreSupport.canonical(URL(fileURLWithPath: sourcePath))
        let root = CoreSupport.canonical(URL(fileURLWithPath: rootPath))
        guard contains(source, in: allowed), contains(root, in: allowed), source != root,
              !contains(source, in: root), !contains(root, in: source) else {
            throw AIManagerError.unsafePath("Real-copy integration paths must be separate children of the authorized validation root")
        }
        return (source, root)
    }

    private func transcriptCatalog(roots: [URL]) throws -> (hashes: Set<String>, byIdentity: [String: [URL]]) {
        var hashes = Set<String>()
        var byIdentity: [String: [URL]] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { continue }
            while let file = enumerator.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true, file.pathExtension == "jsonl" else { continue }
                hashes.insert(try hash(file))
                if let identity = try identity(file) { byIdentity[identity, default: []].append(file) }
            }
        }
        return (hashes, byIdentity)
    }

    private func identity(_ url: URL) throws -> String? {
        let reader = try JSONLReader(url: url)
        for _ in 0..<20 {
            let found: String? = try withAutoreleasePool {
                guard let record = try reader.next(), let object = try JSONSerialization.jsonObject(with: record) as? [String: Any] else { return nil }
                if let payload = object["payload"] as? [String: Any], let id = payload["id"] as? String { return id }
                return object["id"] as? String
            }
            if let found { return found }
        }
        return nil
    }

    private func isRecordPrefix(_ prefix: URL, of complete: URL) throws -> Bool {
        let left = try JSONLReader(url: prefix)
        let right = try JSONLReader(url: complete)
        while true {
            var ended = false
            let equal = try withAutoreleasePool {
                guard let record = try left.next() else { ended = true; return true }
                guard let other = try right.next() else { return false }
                return record == other
            }
            if ended { break }
            guard equal else { return false }
        }
        return try right.next() != nil
    }

    private func unresolvedCategory(_ value: String) -> String {
        if value.contains("divergent") { return "divergent" }
        if value.contains("classification") { return "archive-state" }
        if value.contains("filename collision") { return "filename-collision" }
        if value.contains("source path") { return "source-path" }
        if value.contains("Excluded") || value.contains("excluded") { return "excluded" }
        if value.contains("unsupported") { return "unsupported" }
        return "other"
    }

    private func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            var ended = false
            try withAutoreleasePool {
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                hasher.update(data: data)
            }
            if ended { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
