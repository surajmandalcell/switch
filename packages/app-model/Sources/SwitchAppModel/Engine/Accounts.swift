import Foundation
import AIManagerCore

/// One presented account (`accounts` topic). Holds no credential, digest, or file path.
public struct AccountRow: Codable, Equatable, Sendable {
    public var id: String
    public var providerID: String
    public var label: String
    public var isDefault: Bool
    public var verification: String
    public var verificationDetail: String
    public var needsSignIn: Bool
    public var needsDroidAccess: Bool
    public var plan: String?
    /// Merged usage windows; empty while the account needs a new sign-in.
    public var windows: [UsageWindow]
    public var error: String?
    /// Last good values kept after a failed check.
    public var isOutdated: Bool
    public var isRefreshing: Bool
    public var fetchedAt: Date?
    public var checkedAt: Date?
}

public struct AccountsValue: Codable, Equatable, Sendable {
    public var rows: [AccountRow] = []
}

public enum AccountPresentation {
    /// The account label with the privacy settings applied (settings.md 5.5); `.real` gives the real text.
    public static func label(_ identity: AccountIdentity, _ privacy: PrivacySettings = .real) -> String {
        PrivacyText.label(identity, privacy)
    }

    /// Window ids hidden on one account (`hiddenUsageRows.<UUID>`, newline-joined). The Mac writes the uppercase
    /// UUID; the lowercase form a protocol client would write is read too.
    static func hiddenRows(_ id: UUID, _ store: any SettingsStore) -> Set<String> {
        let keys = Set(["hiddenUsageRows.\(id.uuidString)", "hiddenUsageRows.\(id.uuidString.lowercased())"])
        return Set(keys.flatMap { key -> [String] in
            guard case .string(let text) = store.value(key) else { return [] }
            return text.split(separator: "\n").map(String.init)
        })
    }

    /// The Mac `guiName`: the catalog name ("OpenRouter") except for the four built-in tools.
    public static func providerName(_ provider: ProviderID) -> String {
        [ProviderID.codex, .grokBuild, .droid, .claudeCode].contains(provider)
            ? provider.displayName : (ProviderCatalog.spec(provider)?.name ?? provider.displayName)
    }

    // shortcut: written from view-model.md 1.1 beside AccountViewModel.makeAccountWindows, delete that copy when the
    // Mac app adopts SwitchAppModel.
    /// Codex: the default bucket, then the others by name, each window once, duplicate titles prefixed with the
    /// bucket name. Other providers: the provider's windows. Nothing while the account needs a new sign-in.
    public static func windows(_ account: AccountRecord, codex: CodexAccountUsageSnapshot?,
                               provider: ProviderUsageState?, hidden: Set<String> = []) -> [UsageWindow] {
        if account.verification.state == .needsSignIn { return [] }
        guard account.identity.providerID == .codex else {
            guard let provider, !provider.needsSignIn, let usage = provider.usage else { return [] }
            return usage.windows.filter { !hidden.contains($0.id) }
        }
        guard let limits = codex?.rateLimits else { return [] }
        var seen = Set<String>()
        var result: [(window: UsageWindow, bucket: String)] = []
        func append(_ bucket: CodexRateLimitBucketSnapshot, key: String) {
            guard seen.insert(bucket.id ?? key).inserted else { return }
            let name = CodexBucketNaming.title(id: bucket.id, name: bucket.name, model: bucket.model, fallback: key)
            for row in bucket.windowRows(idPrefix: "\(key)/") where !hidden.contains(row.usage.id) {
                result.append((row.usage, name))
            }
        }
        if let bucket = limits.defaultBucket { append(bucket, key: bucket.id ?? "default") }
        for (key, bucket) in limits.buckets.sorted(by: {
            $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }) { append(bucket, key: key) }
        let titles = result.map(\.window.title)
        return result.map { item in
            var window = item.window
            if titles.filter({ $0 == window.title }).count > 1 { window.title = "\(item.bucket) · \(window.title)" }
            return window
        }
    }
}

extension AppEngine {
    /// Reloads the saved accounts and the Codex cache, then publishes `accounts`.
    func reloadAccounts() async {
        guard let manager else { return }
        do {
            status = try await manager.status()
        } catch {
            setError("Couldn’t load accounts. \(error.localizedDescription)")
            return
        }
        let ids = status?.accounts.map(\.id) ?? []
        if let codexCache, let cached = try? await codexCache.latest(for: ids) {
            codexUsage = Dictionary(uniqueKeysWithValues: cached.map { ($0.accountID, $0) })
        }
        providerUsage = providerUsage.filter { ids.contains($0.key) }
        publishAccounts()
    }

    func publishAccounts() {
        guard let status else { return }
        let privacy = PrivacySettings(settings)
        let rows = status.accounts.map { account -> AccountRow in
            let codex = codexUsage[account.id]
            let provider = providerUsage[account.id]
            let isCodex = account.identity.providerID == .codex
            let needsSignIn = account.verification.state == .needsSignIn || provider?.needsSignIn == true
            return AccountRow(
                id: account.id.uuidString.lowercased(),
                providerID: account.identity.providerID.rawValue,
                label: AccountPresentation.label(account.identity, privacy),
                isDefault: status.defaultAccountIDs[account.identity.providerID.rawValue] == account.id,
                verification: account.verification.state.rawValue,
                verificationDetail: PrivacyText.display(account.verification.detail, privacy),
                needsSignIn: needsSignIn,
                needsDroidAccess: provider?.needsKeychainAccess ?? false,
                plan: isCodex ? codex?.snapshot?.account?.plan : provider?.usage?.plan,
                windows: AccountPresentation.windows(account, codex: codex?.snapshot, provider: provider,
                                                     hidden: AccountPresentation.hiddenRows(account.id, settings)),
                error: (isCodex ? codex?.failureMessage ?? codex?.failure?.message : provider?.error)
                    .map { PrivacyText.display($0, privacy) },
                isOutdated: isCodex ? (codex?.snapshot != nil && codex?.failure != nil) : provider?.isOutdated ?? false,
                isRefreshing: isCodex ? codexRefreshing == account.id : provider?.isRefreshing ?? false,
                fetchedAt: isCodex ? codex?.fetchedAt : provider?.usage?.fetchedAt,
                checkedAt: isCodex ? codex?.lastAttemptAt : provider?.checkedAt)
        }
        publish(.accounts, AccountsValue(rows: rows))
    }

    // MARK: - Codex usage (one account at a time, never in isolation mode)

    func refreshCodexUsage(onCadence: Bool) async {
        guard refreshes, codexRefreshing == nil, let manager, let status else { return }
        let now = clock.now
        let due = status.accounts.filter { account in
            guard account.identity.providerID == .codex else { return false }
            guard let cached = codexUsage[account.id] else { return true }
            return CodexUsagePolicy.isDue(fetchedAt: cached.snapshot == nil ? nil : cached.fetchedAt,
                                          failedAt: cached.failure == nil ? nil : cached.lastAttemptAt,
                                          onCadence: onCadence, now: now)
        }
        for account in due { await refreshCodexAccount(account.id) }
    }

    /// One live Codex check, stored in the Codex usage cache. Does nothing while another Codex check runs.
    func refreshCodexAccount(_ id: UUID) async {
        guard codexRefreshing == nil, let manager else { return }
        codexRefreshing = id
        publishAccounts()
        let result = await manager.checkAccount(accountID: id)
        if result.verification.state == .needsSignIn {
            try? await codexCache?.recordFailure(accountID: id, failure: .authenticationRequired)
        } else if let snapshot = result.usage {
            try? await codexCache?.upsertSuccess(accountID: id, snapshot: snapshot)
        } else {
            try? await codexCache?.recordFailure(accountID: id, failure: .unavailable)
        }
        codexRefreshing = nil
        await reloadAccounts()
        await evaluateAutoSwitch()
    }

    // MARK: - Other providers (four at once, each with a time limit, never in isolation mode)

    func refreshProviderUsage(onCadence: Bool) async {
        guard refreshes, let status else { return }
        let now = clock.now
        let ids = status.accounts.filter { $0.identity.providerID != .codex }.map(\.id)
            .filter { ProviderUsagePolicy.isDue(providerUsage[$0], onCadence: onCadence, now: now) }
        // Not interactive: a credential the provider already rejected is not sent again.
        await refreshProviderAccounts(ids, interactive: false)
    }

    /// Reads usage for `requested` (skipping any read already running). `interactive` only for a user action:
    /// it sends a rejected credential again and may read the login Keychain.
    func refreshProviderAccounts(_ requested: [UUID], interactive: Bool) async {
        guard let manager else { return }
        let ids = requested.filter { providerUsage[$0]?.isRefreshing != true }
        guard !ids.isEmpty else { return }
        for id in ids { providerUsage[id, default: ProviderUsageState()].isRefreshing = true }
        publishAccounts()
        let clock = clock
        await withTaskGroup(of: (UUID, Result<ProviderUsage, Error>).self) { group in
            var pending = ids[...]
            func launch(_ id: UUID) {
                group.addTask {
                    do {
                        return (id, .success(try await ProviderUsagePolicy.withTimeout(
                            ProviderUsagePolicy.fetchTimeout, clock: clock) {
                                try await manager.readProviderUsage(accountID: id, interactive: interactive)
                            }))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for _ in 0..<min(ProviderUsagePolicy.maxConcurrent, ids.count) {
                if let id = pending.popFirst() { launch(id) }
            }
            while let (id, result) = await group.next() {
                applyProviderUsage(id, result)
                if let next = pending.popFirst() { launch(next) }
            }
        }
        await reloadAccounts()
        await evaluateAutoSwitch()
    }

    private func applyProviderUsage(_ id: UUID, _ result: Result<ProviderUsage, Error>) {
        var state = providerUsage[id] ?? ProviderUsageState()
        state.isRefreshing = false
        state.checkedAt = clock.now
        switch result {
        case .success(let usage):
            state.usage = usage
            state.error = nil
            state.providerError = nil
            state.needsSignIn = false
            state.needsKeychainAccess = false
        case .failure(let error):
            let providerError = error as? ProviderError
            state.error = error.localizedDescription
            state.providerError = providerError
            state.needsSignIn = providerError?.needsSignIn ?? false
            state.needsKeychainAccess = error as? DroidLoginError == .needsKeychainAccess
            // Stale numbers never sit beside a sign-in request.
            if state.needsSignIn { state.usage = nil }
        }
        providerUsage[id] = state
        publishAccounts()
    }

    /// Starts the Codex (180 s) and provider (300 s) timers after a first due-based refresh.
    func startUsageTimers() {
        timers.append(repeating(every: CodexUsagePolicy.interval) { await $0.refreshCodexUsage(onCadence: true) })
        timers.append(repeating(every: ProviderUsagePolicy.interval) { await $0.refreshProviderUsage(onCadence: true) })
        timers.append(Task { [weak self] in
            await self?.refreshProviderUsage(onCadence: false)
            await self?.refreshCodexUsage(onCadence: false)
        })
    }

    private func repeating(every interval: TimeInterval,
                           _ body: @escaping @Sendable (AppEngine) async -> Void) -> Task<Void, Never> {
        let clock = clock
        return Task { [weak self] in
            while (try? await clock.sleep(seconds: interval)) != nil {
                guard let self else { return }
                await body(self)
            }
        }
    }
}
