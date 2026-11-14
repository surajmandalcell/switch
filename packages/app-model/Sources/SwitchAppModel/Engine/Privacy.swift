import Foundation
import AIManagerCore

/// The three settings behind every shown email (settings.md 5): `privacyMode` (P), `hideEmailAddresses` (H), and
/// `showEmailDomains` (D).
public struct PrivacySettings: Equatable, Sendable {
    public var privacyMode = false
    public var hideEmails = false
    public var showDomains = false

    /// P off, H off, D on: the real text, for search and sign-in (`realAccountLabel`).
    public static let real = PrivacySettings(showDomains: true)

    init(privacyMode: Bool = false, hideEmails: Bool = false, showDomains: Bool = false) {
        self.privacyMode = privacyMode
        self.hideEmails = hideEmails
        self.showDomains = showDomains
    }

    init(_ store: any SettingsStore) {
        func on(_ key: String) -> Bool { store.effective(key) == .bool(true) }
        self.init(privacyMode: on("privacyMode"), hideEmails: on("hideEmailAddresses"), showDomains: on("showEmailDomains"))
    }
}

// shortcut: written from settings.md 5.2-5.5 beside the Mac EmailPrivacy (ProviderUsageStore.swift); delete that
// copy when the Mac app adopts SwitchAppModel.
/// Email abbreviation, masking, and made-up names, exactly as the Mac `EmailPrivacy` and `displayLabel`.
public enum PrivacyText {
    private static let firstNames = [
        "Jon", "Jane", "Alex", "Sam", "Max", "Mia", "Ben", "Ava", "Leo", "Eva", "Tom", "Zoe",
        "Dan", "Amy", "Ian", "Ivy", "Eli", "Nora", "Luke", "Lucy", "Owen", "Ella", "Finn", "Lily",
    ]
    private static let lastNames = [
        "Doe", "Roe", "Smith", "Park", "Lee", "Hall", "Hill", "Wood", "King", "Gray", "West", "Fox",
        "Reed", "Bell", "Cook", "Cole", "Lane", "Lake", "Stone", "Green", "Young", "Brown", "White", "Hart",
    ]

    /// FNV-1a 64 over the seed's UTF-8 bytes picks a first and a last name.
    public static func fakeName(seed: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "\(firstNames[Int((hash & 0xFFFF_FFFF) % 24)]) \(lastNames[Int((hash >> 32) % 24)])"
    }

    public static func fakeEmail(seed: String) -> String {
        fakeName(seed: seed).lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com"
    }

    /// `a••••@example.com`: four bullets always, so the length is not revealed.
    public static func mask(_ email: String) -> String {
        guard let at = email.lastIndex(of: "@"), at != email.startIndex else { return email }
        return "\(email[email.startIndex])••••\(email[at...])"
    }

    /// Drops the public ending: `ada@mail.co.uk` is `ada@mail`.
    public static func abbreviated(_ email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return email }
        var host = email[email.index(after: at)...].split(separator: ".")
        guard host.count > 1 else { return email }
        let ending = host.removeLast().lowercased()
        let categories: Set<String> = ["co", "com", "net", "org", "gov", "ac", "edu", "sch", "mil", "ltd", "plc", "id",
                                       "ne", "or", "go"]
        if ending.count == 2, host.count > 1, let category = host.last, categories.contains(category.lowercased()) {
            host.removeLast()
        }
        return String(email[...at]) + host.joined(separator: ".")
    }

    private static let pattern = try? NSRegularExpression(
        pattern: #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~•\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+"#)

    /// Every email inside `text`, rewritten by the settings. Privacy mode wins over the other two.
    public static func display(_ text: String, _ settings: PrivacySettings) -> String {
        guard settings.privacyMode || settings.hideEmails || !settings.showDomains, text.contains("@"),
              let pattern else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let email = String(result[range])
            result.replaceSubrange(range, with: settings.privacyMode ? fakeEmail(seed: email.lowercased())
                : settings.hideEmails ? mask(settings.showDomains ? email : abbreviated(email)) : abbreviated(email))
        }
        return result
    }

    /// The account label (settings.md 5.5).
    public static func label(_ identity: AccountIdentity, _ settings: PrivacySettings) -> String {
        let privacy = settings.privacyMode
        if identity.providerID == .droid, let accountID = identity.accountID {
            // One seed for both parts, so the made-up name and email name the same person.
            if privacy { return fakeName(seed: accountID) + (identity.email == nil ? "" : " · \(fakeEmail(seed: accountID))") }
            let name = settings.hideEmails ? mask(accountID) : accountID
            var plain = settings
            plain.privacyMode = false
            return identity.email.map { "\(name) · \(display($0, plain))" } ?? name
        }
        if let email = identity.email, !email.isEmpty { return display(email, settings) }
        if let accountID = identity.accountID, !accountID.isEmpty { return privacy ? fakeName(seed: accountID) : accountID }
        if let userID = identity.userID, !userID.isEmpty, identity.providerID != .codex {
            return privacy ? fakeName(seed: userID)
                : "\(AccountPresentation.providerName(identity.providerID)) ···\(userID.suffix(4))"
        }
        return "Unresolved account"
    }
}
