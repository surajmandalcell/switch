import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum DroidSessionRPCError: LocalizedError, Equatable {
    case couldNotStart
    case timedOut
    case outputTooLarge
    case invalidResponse
    case requestRejected

    public var errorDescription: String? {
        switch self {
        case .couldNotStart: "Factory Droid could not be started."
        case .timedOut: "Factory Droid did not initialize the session in time."
        case .outputTooLarge: "Factory Droid returned an oversized response."
        case .invalidResponse: "Factory Droid returned an invalid session response."
        case .requestRejected: "Factory Droid rejected the session request."
        }
    }
}

public struct DroidSessionRPC: Sendable {
    private static let timeout: TimeInterval = 20
    private static let maximumResponseLine = 1_048_576

    public static func initialize(
        executable: URL,
        home: URL,
        sessionID: UUID,
        cwd: URL,
        title: String,
        settingsFile: URL
    ) throws {
        guard executable.isFileURL, home.isFileURL, cwd.isFileURL, settingsFile.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: home.path),
              FileManager.default.fileExists(atPath: cwd.path),
              FileManager.default.isReadableFile(atPath: settingsFile.path) else {
            throw DroidSessionRPCError.couldNotStart
        }

        let requestID = UUID().uuidString
        let machineID = UUID()
        let request = try makeInitializeRequest(
            requestID: requestID,
            sessionID: sessionID,
            machineID: machineID,
            cwd: cwd,
            title: title
        )
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["FACTORY_HOME_OVERRIDE"] = home.deletingLastPathComponent().path
        environment["HOME"] = home.deletingLastPathComponent().path
        environment.removeValue(forKey: "FACTORY_API_KEY")
        if FileManager.default.fileExists(atPath: home.appending(path: "auth.v2.loginkeychain").path) {
            environment["FACTORY_DISABLE_KEYRING"] = "0"
        } else if FileManager.default.fileExists(atPath: home.appending(path: "auth.v2.key").path) {
            environment["FACTORY_DISABLE_KEYRING"] = "1"
        }
        process.executableURL = executable
        process.arguments = ["exec", "--input-format", "stream-jsonrpc", "-o", "stream-jsonrpc",
                             "--settings", settingsFile.path]
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let collector = ResponseCollector(requestID: requestID, sessionID: sessionID)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            collector.append(data)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
        }
        process.terminationHandler = { _ in collector.processEnded() }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw DroidSessionRPCError.couldNotStart
        }

        defer {
            try? input.fileHandleForWriting.close()
            stop(process)
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }

        do {
            try input.fileHandleForWriting.write(contentsOf: request)
            let deadline = Date().addingTimeInterval(timeout)
            var exitedAt: Date?
            while Date() < deadline {
                if let result = collector.result() {
                    try result.get()
                    return
                }
                if !process.isRunning {
                    if exitedAt == nil { exitedAt = Date() }
                    if let exitedAt, Date().timeIntervalSince(exitedAt) >= 0.5 {
                        if let result = collector.result() {
                            try result.get()
                            return
                        }
                        throw DroidSessionRPCError.invalidResponse
                    }
                }
                _ = collector.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
            }
            throw DroidSessionRPCError.timedOut
        } catch let error as DroidSessionRPCError {
            throw error
        } catch {
            throw DroidSessionRPCError.couldNotStart
        }
    }

    static func makeInitializeRequest(
        requestID: String,
        sessionID: UUID,
        machineID: UUID,
        cwd: URL,
        title: String
    ) throws -> Data {
        let request: [String: Any] = [
            "type": "request",
            "jsonrpc": "2.0",
            "factoryApiVersion": "1.0.0",
            "factoryProtocolVersion": "1.0.0",
            "id": requestID,
            "method": "droid.initialize_session",
            "params": [
                "sessionId": sessionID.uuidString.lowercased(),
                "machineId": machineID.uuidString.lowercased(),
                "cwd": cwd.path,
                "title": title,
                "mcpServers": [],
                "interactionMode": "auto",
                "autonomyLevel": "off",
                "disableBuiltinSkills": true,
                "autoRejectPermissionRequests": true,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: request) + Data([0x0A])
    }

    @discardableResult
    static func validateResponse(_ data: Data, requestID: String, sessionID: UUID) throws -> Bool {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["id"] as? String == requestID else { return false }
        if response["error"] != nil { throw DroidSessionRPCError.requestRejected }
        guard let result = response["result"] as? [String: Any],
              let returnedID = result["sessionId"] as? String,
              UUID(uuidString: returnedID) == sessionID else {
            throw DroidSessionRPCError.invalidResponse
        }
        return true
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let gracefulDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < gracefulDeadline { Thread.sleep(forTimeInterval: 0.025) }
        guard process.isRunning else { process.waitUntilExit(); return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.025) }
        }
        if !process.isRunning { process.waitUntilExit() }
    }

    private final class ResponseCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let signal = DispatchSemaphore(value: 0)
        private let requestID: String
        private let sessionID: UUID
        private var pending = Data()
        private var response: Result<Void, Error>?

        init(requestID: String, sessionID: UUID) {
            self.requestID = requestID
            self.sessionID = sessionID
        }

        func append(_ data: Data) {
            lock.lock()
            guard response == nil else { lock.unlock(); return }
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard line.count <= DroidSessionRPC.maximumResponseLine else {
                    response = .failure(DroidSessionRPCError.outputTooLarge)
                    break
                }
                do {
                    if try DroidSessionRPC.validateResponse(line, requestID: requestID, sessionID: sessionID) {
                        response = .success(())
                        break
                    }
                } catch let error as DroidSessionRPCError {
                    if error == .requestRejected || error == .invalidResponse {
                        response = .failure(error)
                        break
                    }
                } catch {}
            }
            if response == nil && pending.count > DroidSessionRPC.maximumResponseLine {
                response = .failure(DroidSessionRPCError.outputTooLarge)
            }
            let shouldSignal = response != nil
            lock.unlock()
            if shouldSignal { signal.signal() }
        }

        func processEnded() {
            signal.signal()
        }

        func result() -> Result<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return response
        }

        func wait(until deadline: Date) -> Bool {
            signal.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success
        }
    }
}
