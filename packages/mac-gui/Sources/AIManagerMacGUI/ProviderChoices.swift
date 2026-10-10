import AIManagerCore
import Foundation

// The Add Account provider list. Foundation only, so the model checks compile it.

/// One row of the provider list.
struct ProviderChoice: Identifiable, Equatable {
  let id: ProviderID
  let name: String
  let subtitle: String
  let available: Bool
  let unavailableReason: String?
}

enum ProviderChoices {
  static let builtIn: [ProviderID] = [.codex, .grokBuild, .claudeCode]

  /// Every generic provider, alphabetical. Built once: the list never changes while the app runs.
  static let generic: [ProviderChoice] = ProviderCatalog.addable
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    .map { spec in
      ProviderChoice(
        id: spec.id, name: spec.name, subtitle: subtitle(for: spec), available: true,
        unavailableReason: nil)
    }

  /// Codex CLI, Grok Build, and Claude Code first, then the generic providers.
  static func all(descriptors: [ProviderDescriptor]) -> [ProviderChoice] {
    let first = builtIn.compactMap { id in descriptors.first { $0.id == id } }.map { provider in
      ProviderChoice(
        id: provider.id, name: provider.displayName,
        subtitle: provider.availability == .enabled
          ? (provider.id == .codex
            ? "Account switching and usage are supported."
            : "Subscription account switching is supported.")
          : (provider.unavailableReason ?? "Account setup is not available in this version."),
        available: provider.availability == .enabled, unavailableReason: provider.unavailableReason)
    }
    return first + generic
  }

  /// Rows whose name or id contains every word of the query. Diacritics and case are ignored.
  static func filter(_ choices: [ProviderChoice], query: String) -> [ProviderChoice] {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return choices }
    return choices.filter { choice in
      words.allSatisfy { word in
        choice.name.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
          || choice.id.rawValue.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
    }
  }

  static func subtitle(for spec: ProviderSpec) -> String {
    switch spec.style {
    case .files:
      return spec.login == nil
        ? "Saves the sign-in of the official app." : "Saves the sign-in of the official app or CLI."
    case .secret:
      let titles = spec.fields.filter { !$0.optional }.map(\.title)
      return titles.isEmpty ? "Saves a credential." : "Needs: " + titles.joined(separator: ", ") + "."
    }
  }
}
