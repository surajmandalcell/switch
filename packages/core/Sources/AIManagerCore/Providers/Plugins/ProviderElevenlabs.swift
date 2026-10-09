import Foundation

extension ProviderCatalog {
    static let elevenlabs = ProviderSpec(
        id: "elevenlabs", name: "ElevenLabs",
        fields: [.apiKey("ELEVENLABS_API_KEY")],
        dashboard: "https://elevenlabs.io/app/developers/usage",
        usage: { credential in
            let json = try await HTTP.json("https://api.elevenlabs.io/v1/user/subscription",
                                           headers: ["xi-api-key": try credential.require("apiKey")])
            return try ElevenlabsUsage.map(json)
        })
}

enum ElevenlabsUsage {
    static func map(_ data: JSON) throws -> ProviderUsage {
        guard let count = data["character_count"].double, let limit = data["character_limit"].double else {
            throw ProviderError.parse("Failed to parse ElevenLabs response: invalid subscription response")
        }
        var windows = [UsageWindow(id: "credits", title: "Credits", usedPercent: limit > 0 ? count / limit * 100 : 0,
                                   resetsAt: data["next_character_count_reset_unix"].double.flatMap(Fmt.epoch),
                                   detail: "\(Fmt.number(count)) / \(Fmt.number(limit)) credits")]
        for (id, title, used, max) in [("voice-slots", "Voice slots", "voice_slots_used", "voice_limit"),
                                       ("professional-voices", "Professional voices",
                                        "professional_voice_slots_used", "professional_voice_limit")] {
            if let used = data[used].double, let max = data[max].double,
               let window = UsageWindow.amounts(id: id, title: title, used: used, limit: max) {
                windows.append(window)
            }
        }
        let status = data["status"].string
        var plan = status
        if let tier = data["tier"].string?.trimmingCharacters(in: .whitespaces), !tier.isEmpty {
            plan = tier.replacingOccurrences(of: "_", with: " ").capitalized
                + (status.map { $0.lowercased() != "active" ? " · \($0)" : "" } ?? "")
        }
        return ProviderUsage(windows: windows, plan: plan)
    }
}
