import Foundation

/// One Droid mission folder: `<droidHome>/missions/<session id>/`. Switch only reads it.
public struct DroidMission: Identifiable, Equatable, Sendable {
    /// The folder name, which is the session id `droid --resume` takes.
    public var id: String
    public var missionID: String?
    public var state: String
    public var workingDirectory: String
    public var createdAt: Date
    public var updatedAt: Date
    public var title: String
    public var total: Int
    public var completed: Int
    public var cancelled: Int
    /// The saved Droid account that started the mission; nil when unknown.
    public var owner: UUID?

    /// Features that are neither completed nor cancelled.
    public var left: Int { total - completed - cancelled }

    public init(
        id: String, missionID: String? = nil, state: String, workingDirectory: String, createdAt: Date,
        updatedAt: Date, title: String, total: Int, completed: Int, cancelled: Int, owner: UUID? = nil
    ) {
        self.id = id
        self.missionID = missionID
        self.state = state
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.total = total
        self.completed = completed
        self.cancelled = cancelled
        self.owner = owner
    }
}

/// Reads mission folders and writes the "Start here" plan. Never writes into the Droid home.
public enum DroidMissionReader {
    public static func list(droidHome: URL, fileManager: FileManager = .default) -> [DroidMission] {
        let root = droidHome.appending(path: "missions", directoryHint: .isDirectory)
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { read($0, fileManager: fileManager) }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    static func read(_ folder: URL, fileManager: FileManager) -> DroidMission? {
        guard let stateData = fileManager.contents(atPath: folder.appending(path: "state.json").path),
              let state = (try? JSONSerialization.jsonObject(with: stateData)) as? [String: Any] else { return nil }
        guard let features = features(folder, fileManager: fileManager) else { return nil }
        let directory = (state["workingDirectory"] as? String)
            ?? text(folder.appending(path: "working_directory.txt"), fileManager)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let created = date(state["createdAt"]) ?? .distantPast
        return DroidMission(
            id: folder.lastPathComponent, missionID: state["missionId"] as? String,
            state: state["state"] as? String ?? "", workingDirectory: directory,
            createdAt: created, updatedAt: date(state["updatedAt"]) ?? created,
            title: title(of: text(folder.appending(path: "mission.md"), fileManager)) ?? directoryName(directory),
            total: features.count,
            completed: features.filter { $0["status"] as? String == "completed" }.count,
            cancelled: features.filter { $0["status"] as? String == "cancelled" }.count)
    }

    /// A mission with no features file has no features yet (empty); a broken file gives nil.
    static func features(_ folder: URL, fileManager: FileManager) -> [[String: Any]]? {
        guard let data = fileManager.contents(atPath: folder.appending(path: "features.json").path) else { return [] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["features"] as? [[String: Any]]
    }

    private static func text(_ url: URL, _ fileManager: FileManager) -> String? {
        fileManager.contents(atPath: url.path).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func title(of markdown: String?) -> String? {
        markdown?.split(whereSeparator: \.isNewline).first { $0.hasPrefix("# ") }
            .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func directoryName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? "Mission" : name
    }

    /// The Markdown a new mission starts from: the plan, what is done, and what is left.
    public static func plan(folder: String, droidHome: URL, fileManager: FileManager = .default) -> String? {
        let url = droidHome.appending(path: "missions/\(folder)", directoryHint: .isDirectory)
        guard let mission = read(url, fileManager: fileManager) else { return nil }
        func line(_ feature: [String: Any]) -> String {
            "\(feature["id"] as? String ?? "feature"): \(feature["description"] as? String ?? "")"
        }
        let all = features(url, fileManager: fileManager) ?? []
        let done = all.filter { $0["status"] as? String == "completed" }
        let left = all.filter { !["completed", "cancelled"].contains($0["status"] as? String ?? "") }
        var out = [
            "# Continue an earlier Droid mission",
            "This continues an earlier mission that started on another Factory account. Its chat history is not available here. Work in \(mission.workingDirectory). Do not redo finished features. Build only what is left.",
            "## Mission plan",
            text(url.appending(path: "mission.md"), fileManager) ?? mission.title,
            "## Done (do not redo)",
        ]
        out += done.isEmpty ? ["None."] : done.map { "- " + line($0) }
        out.append("## Left")
        for feature in left {
            out.append("### " + line(feature))
            let expected = (feature["expectedBehavior"] as? [String]) ?? []
            if !expected.isEmpty { out.append("Expected behavior:\n" + expected.map { "- " + $0 }.joined(separator: "\n")) }
        }
        if left.isEmpty { out.append("None.") }
        let notes = ["architecture.md", "validation-contract.md"].map { url.appending(path: $0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        if !notes.isEmpty { out += ["## Also read", notes.map { "- " + $0.path }.joined(separator: "\n")] }
        return out.joined(separator: "\n\n") + "\n"
    }

    /// "2 unfinished Droid missions stay with Work. Resume them from Accounts."
    public static func unfinishedNotice(count: Int, owner: String) -> String {
        "\(count) unfinished Droid \(count == 1 ? "mission stays" : "missions stay") with \(owner). Resume them from Accounts."
    }
}

/// `droid-missions.json` in application support: which saved Droid account started which mission.
/// Factory keeps no such record on this Mac, so Switch attributes a mission only when it knows the
/// default account at the time it was created.
struct DroidMissionOwners: Codable, Equatable {
    struct Active: Codable, Equatable {
        var account: UUID
        var since: Date
    }
    var activeSince: Active?
    var owners: [String: UUID] = [:]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func load(_ url: URL) -> Self {
        (try? decoder.decode(Self.self, from: Data(contentsOf: url))) ?? Self()
    }

    func save(_ url: URL, fileManager: FileManager) throws {
        try CoreSupport.atomicWrite(Self.encoder.encode(self), to: url, fileManager: fileManager)
    }

    /// Gives the unowned missions created since `activeSince` to its account.
    mutating func attribute(_ missions: [DroidMission]) {
        guard let active = activeSince else { return }
        for mission in missions where owners[mission.id] == nil && mission.createdAt >= active.since {
            owners[mission.id] = active.account
        }
    }

    /// A refresh sees the default account. A new or changed default starts a fresh window and
    /// attributes nothing: Switch did not see what happened before.
    mutating func refresh(_ missions: [DroidMission], defaultAccount: UUID?, now: Date) {
        guard let defaultAccount else { return }
        if activeSince?.account == defaultAccount { attribute(missions) } else {
            activeSince = Active(account: defaultAccount, since: now)
        }
    }

    /// A Switch switch from `from` to `to`: the old account keeps what started under it.
    mutating func switched(from: UUID?, to: UUID, _ missions: [DroidMission], now: Date) {
        if let from, activeSince?.account == from { attribute(missions) }
        activeSince = Active(account: to, since: now)
    }
}
