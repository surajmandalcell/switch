import Foundation
import AIManagerCore

// Outbound shapes for the read methods. Same rules as WireTypes.swift: no secret fields, lowercase UUID strings,
// plain paths. A running CLI's command line is left out: it can hold a key passed as an argument.

private func lower(_ id: UUID) -> String { id.uuidString.lowercased() }

struct WireDiscoveredSource: Encodable {
    let id: String
    let providerID: String
    let path: String
    let identity: AccountIdentity?
    let support: SourceSupport
    let settings: [String]
    let history: HistorySummary
    let inspectionError: String?

    init(_ source: DiscoveredSource) {
        id = source.id
        providerID = source.providerID.rawValue
        path = source.path.path
        identity = source.identity
        support = source.support
        settings = source.settings
        history = source.history
        inspectionError = source.inspectionError
    }
}

struct WireMission: Encodable {
    let id: String
    let missionID: String?
    let state: String
    let workingDirectory: String
    let createdAt: Date
    let updatedAt: Date
    let title: String
    let total: Int
    let completed: Int
    let cancelled: Int
    let owner: String?

    init(_ mission: DroidMission) {
        id = mission.id
        missionID = mission.missionID
        state = mission.state
        workingDirectory = mission.workingDirectory
        createdAt = mission.createdAt
        updatedAt = mission.updatedAt
        title = mission.title
        total = mission.total
        completed = mission.completed
        cancelled = mission.cancelled
        owner = mission.owner.map(lower)
    }
}

struct WireThread: Encodable {
    let id: String
    let threadID: String
    let title: String
    let preview: String
    let workingDirectory: String?
    let updatedAt: Date
    let archived: Bool
    let messageCount: Int
    let fileByteCount: Int64
    let source: String
    let totalTokens: Int64?
    let appSource: ChatThreadSource
    let model: String?

    init(_ thread: ChatThreadSummary) {
        id = thread.id
        threadID = thread.threadID
        title = thread.title
        preview = thread.preview
        workingDirectory = thread.workingDirectory
        updatedAt = thread.updatedAt
        archived = thread.archived
        messageCount = thread.messageCount
        fileByteCount = thread.fileByteCount
        source = thread.source.path
        totalTokens = thread.totalTokens
        appSource = thread.appSource
        model = thread.model
    }
}

struct WireThreadList: Encodable {
    let threads: [WireThread]
    let total: Int
    let matching: Int
    let skippedFiles: Int
    let unreadableRecords: Int

    init(_ snapshot: ChatHistorySnapshot) {
        threads = snapshot.threads.map(WireThread.init)
        total = snapshot.totalThreadCount
        matching = snapshot.matchingThreadCount
        skippedFiles = snapshot.skippedFileCount
        unreadableRecords = snapshot.unreadableRecordCount
    }
}

struct WireThreadDetail: Encodable {
    struct Message: Encodable {
        let id: String
        let role: String
        let text: String
        let timestamp: Date?
        let model: String?
    }

    let thread: WireThread
    let messages: [Message]
    let omitted: Int
    let matching: Int
    let nextOffset: Int?

    init(_ detail: ChatThreadDetail) {
        thread = WireThread(detail.thread)
        messages = detail.messages.map {
            Message(id: $0.id, role: $0.role.rawValue, text: $0.text, timestamp: $0.timestamp, model: $0.model)
        }
        omitted = detail.omittedMessageCount
        matching = detail.matchingMessageCount
        nextOffset = detail.nextOffset
    }
}

struct WireCleanupSource: Encodable {
    let id: String
    let tool: CleanupTool
    let title: String
    let detail: String
    let providerID: String
    let accountID: String?
    let accountEmail: String?
    let home: String

    init(_ source: CleanupSource) {
        id = source.id
        tool = source.tool
        title = source.title
        detail = source.detail
        providerID = source.providerID.rawValue
        accountID = source.accountID.map(lower)
        accountEmail = source.accountEmail
        home = source.home.path
    }
}

struct WireCleanupBatch: Encodable {
    struct Item: Encodable {
        let id: String
        let path: String
        let companions: [String]
        let title: String
        let project: String?
        let updatedAt: Date
        let bytes: Int64
        let isDirectory: Bool
        let isRewrite: Bool
        let protectedReason: String?
    }

    let id: String
    let createdAt: Date
    let bytes: Int64
    let items: [Item]

    init(_ batch: ConversationCleanupBatch) {
        id = lower(batch.id)
        createdAt = batch.createdAt
        bytes = batch.bytes
        items = batch.items.map {
            Item(id: $0.id, path: $0.path, companions: $0.companions, title: $0.title, project: $0.project,
                 updatedAt: $0.updatedAt, bytes: $0.bytes, isDirectory: $0.isDirectory, isRewrite: $0.isRewrite,
                 protectedReason: $0.protectedReason)
        }
    }
}

struct WireUsageSample: Encodable {
    let id: Int64
    let accountID: String
    let fetchedAt: Date
    let bytes: Int64

    init(_ sample: CleanupUsageSample) {
        id = sample.id
        accountID = lower(sample.accountID)
        fetchedAt = sample.fetchedAt
        bytes = sample.bytes
    }
}

struct WireBackupSet: Encodable {
    let id: String
    let name: String
    let sourceID: String
    let service: BackupSource.Service
    let home: String
    let items: [BackupItem]
    let destination: String
    let includeLogins: Bool
    let promptsOnly: Bool
    let schedule: BackupSchedule
    let keep: Int
    let profiles: [String: String]
    let retired: Bool

    init(_ set: BackupSet) {
        id = lower(set.id)
        name = set.name
        sourceID = set.source.id
        service = set.source.service
        home = set.source.home.path
        items = set.items
        destination = set.destination.path
        includeLogins = set.includeLogins
        promptsOnly = set.promptsOnly
        schedule = set.schedule
        keep = set.keep
        profiles = set.profiles.mapValues(\.path)
        retired = set.retired
    }
}

struct WireBackupStatus: Encodable {
    struct Snapshot: Encodable {
        let id: String
        let folder: String
        let date: Date
        let files: Int
        let totalBytes: Int64
        let newBytes: Int64
        let state: String
    }

    let state: String
    let waitingFor: String?
    let nextDue: Date?
    let lastError: String?
    let snapshots: [Snapshot]

    init(_ status: BackupStatus) {
        switch status.state {
        case .ready: (state, waitingFor) = ("ready", nil)
        case .waiting(let volume): (state, waitingFor) = ("waiting", volume)
        }
        nextDue = status.nextDue
        lastError = status.lastError
        snapshots = status.snapshots.map {
            Snapshot(id: $0.id, folder: $0.folder.path, date: $0.date, files: $0.files, totalBytes: $0.totalBytes,
                     newBytes: $0.newBytes, state: $0.state)
        }
    }
}

struct WireProjectActivity: Encodable {
    let project: String
    let day: String
    let tokens: Int64
    let isComplete: Bool

    init(_ activity: CodexProjectDailyActivity) {
        project = activity.project
        day = activity.day
        tokens = activity.tokens
        isComplete = activity.isComplete
    }
}

struct WireRunningCLI: Encodable {
    let pid: Int32
    let tool: String
    let sessionID: String
    let cwd: String

    init(_ cli: RunningCLI) {
        pid = cli.pid
        tool = cli.tool.rawValue
        sessionID = cli.sessionID
        cwd = cli.cwd
    }
}

/// `usage.history`: the Overview snapshot (one point per day, service, account, model, and project for the last
/// year) and the summary series for the asked period and grouping.
struct WireUsageHistory: Encodable {
    let today: String
    let unavailableSources: [String]
    let points: [UsageHistoryPoint]
    let summary: UsageSummary

    init(_ snapshot: UsageHistorySnapshot, summary: UsageSummary) {
        today = snapshot.today
        unavailableSources = snapshot.unavailableSources
        points = snapshot.points
        self.summary = summary
    }
}

struct WireDaySession: Encodable {
    let id: String
    let service: String
    let accountID: String?
    let threadID: String?
    let project: String
    let model: String?
    let start: Date?
    let tokens: Int64
    let costUSD: Double?

    init(_ session: UsageDaySession) {
        id = session.id
        service = session.service
        accountID = session.accountID
        threadID = session.threadID
        project = session.project
        model = session.model
        start = session.start
        tokens = session.tokens
        costUSD = session.costUSD
    }
}

/// `usage.day`: the day sheet's points, sessions, and the Conversations threads its Codex sessions link to.
struct WireUsageDay: Encodable {
    let day: String
    let points: [UsageHistoryPoint]
    let sessions: [WireDaySession]
    let threads: [WireThread]
}
