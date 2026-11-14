import Foundation
import AIManagerCore

// shortcut: written from ChatMessagePresenter.parse (ChatMessagePresentation.swift) beside the Mac copy; delete that
// when the Mac app adopts SwitchAppModel (needs the window gates).
/// One message of `history.detail` already split into blocks (architecture.md 2.9). Inline text stays inline
/// Markdown (`**bold**`, `` `code` ``, links), which the client renders; block structure is parsed here so every
/// client splits a message the same way.
public struct ChatBlock: Codable, Equatable, Sendable {
    /// `paragraph`, `heading`, `quote`, `unorderedList`, `orderedList`, `table`, `code`, or `divider`.
    public var kind: String
    public var id: Int
    public var text: String?
    /// Heading level 1 to 3.
    public var level: Int?
    public var items: [String]?
    public var headers: [String]?
    public var rows: [[String]]?
    public var language: String?
    /// A code block's text up to 600 lines and 60,000 characters.
    public var preview: String?
    /// The whole code when `preview` was cut ("Show all N lines").
    public var expanded: String?
    public var sourceWasTruncated: Bool?

    init(_ kind: String, _ id: Int, text: String? = nil) {
        self.kind = kind
        self.id = id
        self.text = text
    }

    static let maximumSourceCharacters = 120_000
    static let maximumBlocks = 256
    static let compactCodeLines = 600
    static let compactCodeCharacters = 60_000

    /// The Mac `ChatMessagePresenter.parse`. Tool output is one code block with its spacing kept.
    public static func parse(_ message: ChatMessage) -> [ChatBlock] {
        let truncated = message.text.count > maximumSourceCharacters
        let source = String(message.text.prefix(maximumSourceCharacters)).replacingOccurrences(of: "\r\n", with: "\n")
        func code(_ id: Int, _ lines: [String], full: String, language: String?, cut: Bool) -> ChatBlock {
            let compact = String(lines.prefix(compactCodeLines).joined(separator: "\n").prefix(compactCodeCharacters))
            var block = ChatBlock("code", id)
            block.language = language
            block.preview = compact
            block.expanded = compact.count == full.count ? nil : full
            block.sourceWasTruncated = cut
            return block
        }
        if message.role == .tool {
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return [code(0, lines, full: source, language: nil, cut: truncated)]
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [ChatBlock] = []
        var index = 0
        while index < lines.count && blocks.count < maximumBlocks {
            let id = blocks.count
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") {
                // The fence closes on a line of at least as many backticks and nothing else.
                let fence = trimmed.prefix(while: { $0 == "`" }).count
                let language = String(trimmed.dropFirst(fence)).trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !isClosingFence(lines[index], length: fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(code(id, codeLines, full: codeLines.joined(separator: "\n"),
                                   language: language.isEmpty ? nil : language, cut: truncated && index >= lines.count))
                continue
            }
            if index + 1 < lines.count, let headers = tableHeader(line, separator: lines[index + 1]) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let cells = tableCells(lines[index]) {
                    rows.append((0..<headers.count).map { $0 < cells.count ? cells[$0] : "" })
                    index += 1
                }
                var block = ChatBlock("table", id)
                block.headers = headers
                block.rows = rows
                blocks.append(block)
                continue
            }
            if let heading = heading(in: trimmed) {
                var block = ChatBlock("heading", id, text: heading.text)
                block.level = heading.level
                blocks.append(block)
                index += 1
                continue
            }
            if ["---", "***", "___"].contains(trimmed) {
                blocks.append(ChatBlock("divider", id))
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quote.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(ChatBlock("quote", id, text: quote.joined(separator: "\n")))
                continue
            }
            for (kind, item) in [("unorderedList", unorderedItem), ("orderedList", orderedItem)] where item(trimmed) != nil {
                var items: [String] = []
                while index < lines.count, let next = item(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                var block = ChatBlock(kind, id)
                block.items = items
                blocks.append(block)
            }
            if blocks.count > id { continue }
            var paragraph: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                guard !candidate.isEmpty, !startsBlock(candidate) || paragraph.isEmpty else { break }
                if !paragraph.isEmpty, index + 1 < lines.count, tableHeader(candidate, separator: lines[index + 1]) != nil {
                    break
                }
                paragraph.append(lines[index])
                index += 1
                if paragraph.count == 1 && startsBlock(candidate) { break }
            }
            blocks.append(ChatBlock("paragraph", id, text: paragraph.joined(separator: "\n")))
        }
        if blocks.isEmpty { return [ChatBlock("paragraph", 0, text: source)] }
        // The message was cut at 120,000 characters or 256 blocks: the last block says so.
        if truncated || blocks.count == maximumBlocks { blocks[blocks.count - 1].sourceWasTruncated = true }
        return blocks
    }

    private static func isClosingFence(_ line: String, length: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == "`" }
    }

    private static func tableHeader(_ line: String, separator: String) -> [String]? {
        guard let headers = tableCells(line), let rules = tableCells(separator), headers.count == rules.count,
              rules.allSatisfy({ cell in
                  let rule = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                  return rule.count >= 3 && rule.allSatisfy { $0 == "-" }
              }) else { return nil }
        return headers
    }

    /// Cells split on `|` outside inline code; `\|` is a literal bar.
    private static func tableCells(_ line: String) -> [String]? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.contains("|") else { return nil }
        var cells = [String]()
        var cell = ""
        var escaped = false
        var codeTicks = 0
        var pendingTicks = 0
        for character in text {
            if escaped {
                if character != "|", character != "\\" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "`" {
                pendingTicks += 1
                cell.append(character)
            } else {
                if pendingTicks > 0 {
                    if codeTicks == 0 { codeTicks = pendingTicks } else if codeTicks == pendingTicks { codeTicks = 0 }
                    pendingTicks = 0
                }
                if character == "\\" {
                    escaped = true
                } else if character == "|", codeTicks == 0 {
                    cells.append(cell.trimmingCharacters(in: .whitespaces))
                    cell = ""
                } else {
                    cell.append(character)
                }
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if text.first == "|" { cells.removeFirst() }
        if text.last == "|", cells.last == "" { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(level), line.dropFirst(level).first == " " else { return nil }
        return (level, String(line.dropFirst(level + 1)))
    }

    private static func unorderedItem(_ line: String) -> String? {
        guard line.count > 2, ["- ", "* ", "+ "].contains(line.prefix(2)) else { return nil }
        return String(line.dropFirst(2))
    }

    private static func orderedItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."), dot != line.startIndex, line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " ", line[..<dot].allSatisfy(\.isNumber) else { return nil }
        return String(line[line.index(dot, offsetBy: 2)...])
    }

    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix(">") || heading(in: line) != nil || unorderedItem(line) != nil
            || orderedItem(line) != nil || ["---", "***", "___"].contains(line)
    }
}
