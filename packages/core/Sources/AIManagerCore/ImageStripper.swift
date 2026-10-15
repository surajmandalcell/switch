import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Swaps the inline base64 pictures of a transcript (`.jsonl`) for a 1x1 PNG. Only the picture bytes change,
/// so every line still parses and the chat still resumes. Byte search, not JSON parsing: the rest of each
/// line stays byte for byte the same.
///
/// Codex: any string `"data:image/...;base64,<payload>"` (`input_image` items and `images` lists).
/// Claude Code: `{"type":"base64","media_type":"...","data":"<payload>"}`.
enum ImageStripper {
    static let tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    /// Shorter payloads are thumbnails or text that only looks like a picture.
    static let minPayload = 2_048
    /// One transcript line can hold several pictures; a line past this size is left alone.
    static let maxLine = 256 << 20

    private struct Edit { let start: Int; let end: Int; let replacement: [UInt8] }

    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), newline = UInt8(10)
    private static let tiny = Array(tinyPNG.utf8)
    private static let dataURL = Array("data:image/".utf8)
    private static let base64Type = Array("\"type\":\"base64\"".utf8)
    private static let mediaKey = Array(",\"media_type\":\"".utf8)
    private static let dataKey = Array("\",\"data\":\"".utf8)
    private static let urlReplacement = Array("data:image/png;base64,".utf8) + tiny
    private static let mediaReplacement = Array("image/png\",\"data\":\"".utf8) + tiny
    /// Base64 letters, plus the backslash of an escaped slash.
    private static let payloadByte: [Bool] = (0..<256).map { value in
        let byte = UInt8(value)
        return (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            || byte == 43 || byte == 47 || byte == 61 || byte == backslash
    }

    // MARK: Search

    private static func find(_ needle: [UInt8], in buffer: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard let base = buffer.baseAddress, from < buffer.count else { return nil }
        return needle.withUnsafeBufferPointer { pattern in
            guard let hit = memmem(base + from, buffer.count - from, pattern.baseAddress!, pattern.count) else { return nil }
            return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        }
    }

    private static func matches(_ needle: [UInt8], in buffer: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        index + needle.count <= buffer.count && needle.indices.allSatisfy { buffer[index + $0] == needle[$0] }
    }

    /// The end of a payload that starts at `start` and ends at a closing quote, or nil.
    private static func payloadEnd(in buffer: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var index = start
        while index < buffer.count, payloadByte[Int(buffer[index])] { index += 1 }
        guard index < buffer.count, buffer[index] == quote, index - start >= minPayload else { return nil }
        return index
    }

    private static func edits(in buffer: UnsafeBufferPointer<UInt8>) -> [Edit] {
        var result: [Edit] = []
        var at = 0
        var nextURL: Int?, nextBase: Int?
        var searchedURL = -1, searchedBase = -1
        while at < buffer.count {
            if searchedURL < at { nextURL = find(dataURL, in: buffer, from: at); searchedURL = nextURL ?? Int.max }
            if searchedBase < at { nextBase = find(base64Type, in: buffer, from: at); searchedBase = nextBase ?? Int.max }
            switch (nextURL, nextBase) {
            case (nil, nil): return result
            case (let url?, let base) where base == nil || url < base!:
                at = url + dataURL.count
                // A real string value: opened by a quote that is not itself escaped.
                guard url > 0, buffer[url - 1] == quote, !(url > 1 && buffer[url - 2] == backslash) else { continue }
                var cursor = at
                while cursor < buffer.count, cursor - at < 16, buffer[cursor] != UInt8(ascii: ";") { cursor += 1 }
                let marker = Array(";base64,".utf8)
                guard matches(marker, in: buffer, at: cursor) else { continue }
                let start = cursor + marker.count
                guard let end = payloadEnd(in: buffer, from: start) else { continue }
                result.append(Edit(start: url, end: end, replacement: urlReplacement))
                at = end
            case (_, let base?):
                at = base + base64Type.count
                guard matches(mediaKey, in: buffer, at: at) else { continue }
                let mimeStart = at + mediaKey.count
                var cursor = mimeStart
                while cursor < buffer.count, cursor - mimeStart < 40, buffer[cursor] != quote, buffer[cursor] != newline { cursor += 1 }
                guard matches(dataKey, in: buffer, at: cursor) else { continue }
                let start = cursor + dataKey.count
                guard let end = payloadEnd(in: buffer, from: start) else { continue }
                result.append(Edit(start: mimeStart, end: end, replacement: mediaReplacement))
                at = end
            default: return result
            }
        }
        return result
    }

    // MARK: Files

    /// Reads the file in pieces cut at line ends and passes each piece through the edits.
    /// With `output` the stripped copy is written; either way the bytes saved come back.
    private static func run(_ source: URL, output: FileHandle?) throws -> Int64 {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var pending: [UInt8] = []
        var saved: Int64 = 0
        func emit(_ end: Int) throws {
            try Task.checkCancellation()
            let found = pending.withUnsafeBufferPointer { edits(in: UnsafeBufferPointer(rebasing: $0[0..<end])) }
            var copied = 0
            for edit in found {
                if let output, edit.start > copied { try output.write(contentsOf: Data(pending[copied..<edit.start])) }
                if let output { try output.write(contentsOf: Data(edit.replacement)) }
                copied = edit.end
                saved += Int64(edit.end - edit.start - edit.replacement.count)
            }
            if let output, copied < end { try output.write(contentsOf: Data(pending[copied..<end])) }
            pending.removeFirst(end)
        }
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
            chunk.withUnsafeBytes { pending.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
            if let last = pending.lastIndex(of: newline) {
                try emit(last + 1)
            } else if pending.count > maxLine {
                throw AIManagerError.operationFailed("A transcript line is too large to rewrite.")
            }
        }
        if !pending.isEmpty { try emit(pending.count) }
        return saved
    }

    private final class Remembered: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Int64] = [:]
    }
    private static let remembered = Remembered()

    /// Bytes a rewrite would save. Remembered per file, size and modified time, so a reload costs nothing.
    static func savings(of url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_size > Int64(minPayload) else { return 0 }
        let key = "\(url.path)|\(info.st_size)|\(CleanupScanner.modified(info))"
        remembered.lock.lock()
        let known = remembered.values[key]
        remembered.lock.unlock()
        if let known { return known }
        // A read that failed or was cancelled is not remembered.
        guard let value = try? run(url, output: nil) else { return 0 }
        remembered.lock.lock()
        remembered.values[key] = value
        remembered.lock.unlock()
        return value
    }

    /// Writes the stripped copy of `source` to `temporary` with the same permissions and times.
    /// Returns the bytes saved; the caller removes `temporary` when that is zero.
    static func rewrite(_ source: URL, to temporary: URL) throws -> Int64 {
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AIManagerError.sourceChanged }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AIManagerError.operationFailed("Cleanup could not write next to the chat.")
        }
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            let saved = try run(source, output: output)
            try output.synchronize()
            guard fchmod(output.fileDescriptor, info.st_mode & 0o7777) == 0 else { throw AIManagerError.sourceChanged }
            #if canImport(Darwin)
            var times = [info.st_atimespec, info.st_mtimespec]
            #else
            var times = [info.st_atim, info.st_mtim]
            #endif
            guard futimens(output.fileDescriptor, &times) == 0 else { throw AIManagerError.sourceChanged }
            return saved
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
