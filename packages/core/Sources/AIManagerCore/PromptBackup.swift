import Foundation

/// Reads only transcript files. Settings, login files, images, and tool results never enter the export.
enum PromptBackup {
    struct Document {
        let title: String
        let project: String
        let date: Date
        let app: String
        let prompts: [ChatMessage]

        var markdown: String {
            let formatter = ISO8601DateFormatter()
            let ordered = prompts.enumerated().sorted {
                let left = $0.element.timestamp ?? date
                let right = $1.element.timestamp ?? date
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
            return "# \(PromptBackup.inline(title))\n\nProject: \(PromptBackup.inline(project))\nDate: \(formatter.string(from: date))\nApp: \(app)\n\n"
                + ordered.map { "## \($0.timestamp.map(formatter.string(from:)) ?? "Unknown time")\n\n\($0.text)\n" }.joined(separator: "\n")
        }
    }

    static func isConversationRoot(_ path: String, service: BackupSource.Service) -> Bool {
        let roots: [String]
        switch service {
        case .codex, .grok: roots = ["sessions", "archived_sessions"]
        case .claude: roots = ["projects", "sessions"]
        case .droid: roots = ["sessions"]
        case .gemini: roots = ["tmp"]
        }
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func isTranscript(_ path: String, service: BackupSource.Service) -> Bool {
        guard isConversationRoot(path, service: service), !BackupPresets.isLogin(path) else { return false }
        let parts = path.split(separator: "/")
        switch service {
        case .codex: return path.hasSuffix(".jsonl")
        case .claude: return path.hasSuffix(".jsonl") && !parts.contains("subagents")
        case .droid: return path.hasSuffix(".jsonl")
        case .grok: return parts.count == 4 && ["updates.jsonl", "chat_history.jsonl"].contains(parts.last ?? "")
        case .gemini: return path.hasSuffix(".json") && parts.contains("chats")
        }
    }

    static func read(_ url: URL, path: String, service: BackupSource.Service) throws -> Document? {
        if service == .grok, url.lastPathComponent == "chat_history.jsonl",
           CoreSupport.entryExists(url.deletingLastPathComponent().appending(path: "updates.jsonl")) { return nil }
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        if service == .codex {
            let (thread, prompts) = try ChatHistoryIndex.prompts(at: url)
            guard !prompts.isEmpty else { return nil }
            return Document(title: thread.title, project: thread.workingDirectory ?? "No project", date: thread.updatedAt,
                app: thread.appSource.displayLabel, prompts: prompts)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            if let text = value as? String { return fractional.date(from: text) ?? whole.date(from: text) }
            if let number = value as? Double { return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number) }
            return nil
        }
        var prompts: [ChatMessage] = []
        var project: String?
        var title: String?
        var started: Date?
        var grokChunkOpen = false
        func record(_ object: [String: Any]) {
            if project == nil { project = object["cwd"] as? String ?? object["workingDirectory"] as? String }
            if title == nil { title = object["title"] as? String }
            if started == nil { started = date(object["startTime"] ?? object["timestamp"]) }
            guard object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true else { return }
            if service == .grok, let params = object["params"] as? [String: Any], let update = params["update"] as? [String: Any] {
                guard update["sessionUpdate"] as? String == "user_message_chunk" else { grokChunkOpen = false; return }
                guard let content = update["content"] as? [String: Any], content["type"] as? String == "text",
                      let text = content["text"] as? String, !text.isEmpty else { return }
                if grokChunkOpen, let last = prompts.last {
                    prompts[prompts.count - 1] = ChatMessage(id: last.id, role: .user, text: last.text + text, timestamp: last.timestamp)
                } else {
                    let meta = update["_meta"] as? [String: Any] ?? params["_meta"] as? [String: Any]
                    prompts.append(ChatMessage(id: String(prompts.count), role: .user, text: text,
                        timestamp: date(object["timestamp"] ?? meta?["timestamp"] ?? meta?["agentTimestampMs"])))
                }
                grokChunkOpen = true
                return
            }
            let message = object["message"] as? [String: Any] ?? object
            guard message["role"] as? String == "user" || ([BackupSource.Service.gemini, .grok].contains(service) && message["type"] as? String == "user") else { return }
            if service == .grok, let reason = message["synthetic_reason"] as? String,
               !["human", "interjection", "parent_human_message"].contains(reason) { return }
            let text: String
            if let content = message["content"] as? String { text = content }
            else if let parts = message["content"] as? [[String: Any]] {
                text = parts.filter { ["text", "input_text"].contains($0["type"] as? String ?? "") }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else { return }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !ChatTitlePolicy.isBootstrapContext(text) else { return }
            prompts.append(ChatMessage(id: String(prompts.count), role: .user, text: text,
                timestamp: date(object["timestamp"] ?? message["timestamp"])))
        }
        if url.pathExtension == "jsonl" {
            let reader = try JSONLReader(url: url)
            while let line = try reader.next() {
                try Task.checkCancellation()
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw BackupError.changed(path)
                }
                record(object)
            }
        } else {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            if let object = object as? [String: Any] {
                record(object)
                for message in object["messages"] as? [[String: Any]] ?? [] { try Task.checkCancellation(); record(message) }
            } else if let messages = object as? [[String: Any]] {
                for message in messages { try Task.checkCancellation(); record(message) }
            }
        }
        prompts.removeAll { ChatTitlePolicy.isBootstrapContext($0.text) || (service == .grok && ["<user_info>", "<system-reminder>"].contains(where: $0.text.hasPrefix)) }
        guard !prompts.isEmpty else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        let fallback = parts.count > 2 ? parts[1] : "No project"
        let projectPath = project ?? (service == .grok ? fallback.removingPercentEncoding : CleanupScanner.decodeProjectFolder(fallback)) ?? fallback
        let app: String
        switch service {
        case .claude: app = "Claude Code"
        case .droid: app = "Droid"
        case .grok: app = "Grok Build"
        case .gemini: app = "Gemini CLI"
        case .codex: app = "Codex"
        }
        return Document(title: title ?? String(prompts[0].text.prefix(100)), project: projectPath,
            date: started ?? prompts.first?.timestamp ?? modified, app: app, prompts: prompts)
    }

    static func inline(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    static func folder(_ text: String) -> String {
        let name = String(text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(String(scalar)) : "-"
        }.prefix(48))
        return (name.isEmpty ? "project" : name) + "-" + CoreSupport.digest(Data(text.utf8)).prefix(12)
    }
}
