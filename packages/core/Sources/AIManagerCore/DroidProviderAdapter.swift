import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct DroidProcess: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String?
    /// Nil means the home could not be proved; require confirmation rather than guess.
    public var home: URL?
    public init(pid: Int32, bundleID: String? = nil, home: URL? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.home = home
    }
}

public enum DroidAccountError: LocalizedError, Equatable {
    case running([DroidProcess])
    case confirmSignIn(String)
    case loginInProgress
    case existingLoginRequired
    case writeLockBusy
    case duplicateIdentity(name: String, hint: String)

    public var errorDescription: String? {
        switch self {
        case .running: "Factory.app is running. Switching changes its account for new requests."
        case .confirmSignIn(let name): "Sign in to \(name)? Droid's masked email cannot prove the full account identity."
        case .loginInProgress: "A Droid sign-in is already open. Finish or cancel it before starting another."
        case .existingLoginRequired: "Sign in to Factory on this Mac first, then add a Droid account. An existing login is required for the shared encryption key."
        case .writeLockBusy: "Droid is writing its login, or its write lock needs attention. Finish that operation and retry."
        case .duplicateIdentity(let name, let hint): "This looks like \(name) (\(hint)). Add it anyway?"
        }
    }
}

struct DroidProviderAdapter {
    static let authNames = ["auth.v2.key", "auth.v2.file", "auth.v2.loginkeychain"]
    let fileManager: FileManager

    static func identityHint(_ data: Data) -> String? {
        guard data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return nil }
        let matches = results.filter { $0["id"] as? String == "auth.verify" }
        guard matches.count == 1, matches[0]["status"] as? String == "pass",
              let detail = matches[0]["detail"] as? String else { return nil }
        let prefix = "authenticated as ", suffix = " via stored login session"
        guard detail.hasPrefix(prefix), detail.hasSuffix(suffix) else { return nil }
        let hint = String(detail.dropFirst(prefix.count).dropLast(suffix.count))
        guard hint.count <= 320, hint.contains("*"),
              hint.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else { return nil }
        return hint.lowercased()
    }

    func doctor(executable: URL, home: URL, keyring: Bool) -> String? {
        let output = home.appending(path: "doctor-output.json")
        do {
            try CoreSupport.atomicWrite(Data(), to: output, fileManager: fileManager)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close(); try? fileManager.removeItem(at: output) }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["doctor", "--auth", "--json"]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "FACTORY_API_KEY")
            environment["HOME"] = home.path
            environment["FACTORY_HOME_OVERRIDE"] = home.path
            environment["FACTORY_DISABLE_KEYRING"] = keyring ? "0" : "1"
            process.environment = environment
            process.currentDirectoryURL = home
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline {
                let size = (try? fileManager.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > 65_536 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                // Bound shutdown even if the executable ignores SIGTERM.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return nil
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let size = try fileManager.attributesOfItem(atPath: output.path)[.size] as? NSNumber,
                  size.intValue <= 65_536 else { return nil }
            return Self.identityHint(try Data(contentsOf: output))
        } catch { return nil }
    }

    func files(in home: URL) throws -> [String: Data] {
        guard CoreSupport.entryExists(home) else { return [:] }
        var info = stat()
        guard lstat(home.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw AIManagerError.unsafePath("Droid login directory must be owner-private and cannot be a link.")
        }
        var result: [String: Data] = [:]
        for name in Self.authNames {
            let url = home.appending(path: name)
            guard CoreSupport.entryExists(url) else { continue }
            try GrokProviderAdapter(fileManager: fileManager).validatePrivateCredentialFile(url)
            guard lstat(url.path, &info) == 0, info.st_size > 0, info.st_size <= CoreSupport.maxAuthBytes else {
                throw AIManagerError.credentialConflict
            }
            result[name] = try Data(contentsOf: url)
        }
        guard result["auth.v2.file"] == nil || result["auth.v2.key"] != nil,
              result["auth.v2.key"] == nil || result["auth.v2.file"] != nil else {
            throw AIManagerError.credentialConflict
        }
        return result
    }

    func requireLogin(_ files: [String: Data]) throws {
        guard files["auth.v2.loginkeychain"] != nil || files["auth.v2.file"] != nil else {
            throw DroidAccountError.existingLoginRequired
        }
    }

    /// Droid publishes a nonempty lock directory by rename, with {token,pid} in owner.json.
    /// Never reclaim another process's lock; Droid can apply its own stale-lock policy.
    func withWriteLock<T>(home: URL, _ body: () throws -> T) throws -> T {
        let token = UUID().uuidString
        let pending = home.appending(path: "auth.v2.write.\(CoreSupport.digest(Data(token.utf8)).prefix(32)).pending")
        let lock = home.appending(path: "auth.v2.write.lock")
        try CoreSupport.privateDirectory(pending, fileManager: fileManager)
        defer { try? fileManager.removeItem(at: pending) }
        let owner = try JSONSerialization.data(withJSONObject: ["token": token, "pid": Int(getpid())])
        try CoreSupport.atomicWrite(owner, to: pending.appending(path: "owner.json"), fileManager: fileManager)
        guard !CoreSupport.entryExists(lock),
              !CoreSupport.entryExists(home.appending(path: "auth.v2.write.lock.reclaim")),
              rename(pending.path, lock.path) == 0 else { throw DroidAccountError.writeLockBusy }
        defer {
            if let data = try? Data(contentsOf: lock.appending(path: "owner.json")),
               let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               record["token"] as? String == token {
                try? fileManager.removeItem(at: lock)
            }
        }
        return try body()
    }

    static func processes() throws -> [DroidProcess] {
        // Read executable names only, never process environments or credential-bearing arguments.
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0, data.count < 4 * 1_024 * 1_024 else { throw AIManagerError.writerStateUnknown }
        var result = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> DroidProcess? in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int32(parts[0]),
                  URL(fileURLWithPath: String(parts[1])).lastPathComponent.lowercased() == "droid" else { return nil }
            return DroidProcess(pid: pid)
        }
        #if canImport(AppKit)
        result += NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.electron.factory" }
            .map { DroidProcess(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier) }
        #endif
        return result
    }
}
