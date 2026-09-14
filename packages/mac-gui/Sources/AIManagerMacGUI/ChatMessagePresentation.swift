import AIManagerCore
import Foundation

struct ChatMessagePresentation: Identifiable, Equatable, Sendable {
  let id: String
  let blocks: [ChatPresentationBlock]
  let sourceWasTruncated: Bool
}

enum ChatPresentationBlock: Identifiable, Equatable, Sendable {
  case paragraph(Int, AttributedString)
  case heading(Int, level: Int, text: AttributedString)
  case quote(Int, AttributedString)
  case unorderedList(Int, [AttributedString])
  case orderedList(Int, [AttributedString])
  case code(Int, language: String?, preview: String, expanded: String?, sourceWasTruncated: Bool)
  case divider(Int)

  var id: Int {
    switch self {
    case let .paragraph(id, _), let .heading(id, _, _), let .quote(id, _),
      let .unorderedList(id, _), let .orderedList(id, _), let .code(id, _, _, _, _),
      let .divider(id):
      id
    }
  }
}

enum ChatMessagePresenter {
  static let maximumSourceCharacters = 120_000
  static let maximumBlocks = 256
  static let compactCodeLines = 24
  static let compactCodeCharacters = 8_192

  static func render(
    messages: [ChatMessage]
  ) async throws -> [String: ChatMessagePresentation] {
    let task = Task.detached(priority: .userInitiated) {
      var result: [String: ChatMessagePresentation] = [:]
      result.reserveCapacity(messages.count)
      for (index, message) in messages.enumerated() {
        if index.isMultiple(of: 8) { try Task.checkCancellation() }
        result[message.id] = try parse(message)
      }
      return result
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  static func parse(_ message: ChatMessage) throws -> ChatMessagePresentation {
    let sourceWasTruncated = message.text.count > maximumSourceCharacters
    let source = String(message.text.prefix(maximumSourceCharacters))
      .replacingOccurrences(of: "\r\n", with: "\n")
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var blocks: [ChatPresentationBlock] = []
    var index = 0
    var blockID = 0

    func nextID() -> Int {
      defer { blockID += 1 }
      return blockID
    }

    while index < lines.count && blocks.count < maximumBlocks {
      if index.isMultiple(of: 16) { try Task.checkCancellation() }
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        index += 1
        continue
      }

      if trimmed.hasPrefix("```") {
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        index += 1
        var codeLines: [String] = []
        while index < lines.count,
          !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```")
        {
          if index.isMultiple(of: 16) { try Task.checkCancellation() }
          codeLines.append(lines[index])
          index += 1
        }
        if index < lines.count { index += 1 }
        let fullCode = codeLines.joined(separator: "\n")
        let compactLines = codeLines.prefix(compactCodeLines).joined(separator: "\n")
        let compact = String(compactLines.prefix(compactCodeCharacters))
        let isCompact = compact.count == fullCode.count
        blocks.append(.code(
          nextID(), language: language.isEmpty ? nil : language,
          preview: compact, expanded: isCompact ? nil : fullCode,
          sourceWasTruncated: sourceWasTruncated && index >= lines.count))
        continue
      }

      if let heading = heading(in: trimmed) {
        blocks.append(.heading(nextID(), level: heading.level, text: inline(heading.text)))
        index += 1
        continue
      }

      if trimmed == "---" || trimmed == "***" || trimmed == "___" {
        blocks.append(.divider(nextID()))
        index += 1
        continue
      }

      if trimmed.hasPrefix(">") {
        var quoteLines: [String] = []
        while index < lines.count {
          let candidate = lines[index].trimmingCharacters(in: .whitespaces)
          guard candidate.hasPrefix(">") else { break }
          quoteLines.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
          index += 1
        }
        blocks.append(.quote(nextID(), inline(quoteLines.joined(separator: "\n"))))
        continue
      }

      if unorderedItem(in: trimmed) != nil {
        var items: [AttributedString] = []
        while index < lines.count,
          let item = unorderedItem(in: lines[index].trimmingCharacters(in: .whitespaces))
        {
          items.append(inline(item))
          index += 1
        }
        blocks.append(.unorderedList(nextID(), items))
        continue
      }

      if orderedItem(in: trimmed) != nil {
        var items: [AttributedString] = []
        while index < lines.count,
          let item = orderedItem(in: lines[index].trimmingCharacters(in: .whitespaces))
        {
          items.append(inline(item))
          index += 1
        }
        blocks.append(.orderedList(nextID(), items))
        continue
      }

      var paragraph: [String] = []
      while index < lines.count {
        let candidate = lines[index].trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty, !startsBlock(candidate) || paragraph.isEmpty else { break }
        paragraph.append(lines[index])
        index += 1
        if paragraph.count == 1 && startsBlock(candidate) { break }
      }
      blocks.append(.paragraph(nextID(), inline(paragraph.joined(separator: "\n"))))
    }

    return ChatMessagePresentation(
      id: message.id,
      blocks: blocks.isEmpty ? [.paragraph(0, AttributedString(source))] : blocks,
      sourceWasTruncated: sourceWasTruncated || blocks.count == maximumBlocks)
  }

  private static func inline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text)) ?? AttributedString(text)
  }

  private static func heading(in line: String) -> (level: Int, text: String)? {
    let level = line.prefix(while: { $0 == "#" }).count
    guard (1...3).contains(level), line.dropFirst(level).first == " " else { return nil }
    return (level, String(line.dropFirst(level + 1)))
  }

  private static func unorderedItem(in line: String) -> String? {
    guard line.count > 2 else { return nil }
    let prefix = line.prefix(2)
    guard prefix == "- " || prefix == "* " || prefix == "+ " else { return nil }
    return String(line.dropFirst(2))
  }

  private static func orderedItem(in line: String) -> String? {
    guard let delimiter = line.firstIndex(of: "."),
      delimiter != line.startIndex,
      line.index(after: delimiter) < line.endIndex,
      line[line.index(after: delimiter)] == " ",
      line[..<delimiter].allSatisfy(\.isNumber)
    else { return nil }
    return String(line[line.index(delimiter, offsetBy: 2)...])
  }

  private static func startsBlock(_ line: String) -> Bool {
    line.hasPrefix("```") || line.hasPrefix(">") || heading(in: line) != nil
      || unorderedItem(in: line) != nil || orderedItem(in: line) != nil
      || line == "---" || line == "***" || line == "___"
  }
}
