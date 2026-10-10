import Foundation

/// A small virtual terminal for Claude Code's `/usage` panel (ported from CodexBar's ClaudeCLIScreen).
/// It replays cursor moves, erases, scrolling and the alternate screen, so the text it returns is what
/// a person would see, however the program redrew it. Colors and other styling are ignored.
struct ClaudeTerminalScreen {
    /// Keep the PTY and the screen well taller than the panel, so no quota row scrolls out of reach.
    static let defaultColumns = 160
    static let defaultRows = 200

    let columns: Int
    let rows: Int
    private var grid: [[Unicode.Scalar]]
    private var savedMain: (grid: [[Unicode.Scalar]], row: Int, column: Int)?
    private var saved = (row: 0, column: 0)
    private var row = 0
    private var column = 0
    private var pending: [UInt8] = []
    private var state = State.ground
    private var params = ""

    private enum State { case ground, escape, csi, osc, oscEscape, skipOne }

    init(columns: Int = defaultColumns, rows: Int = defaultRows) {
        self.columns = columns
        self.rows = rows
        grid = Self.blankGrid(columns: columns, rows: rows)
    }

    /// The text of a finished byte stream, for example a captured transcript.
    static func render(_ text: String) -> String {
        var screen = Self()
        screen.feed(Data(text.utf8))
        return screen.text
    }

    /// The visible rows, trailing blanks removed.
    var text: String {
        var lines = grid.map { line in
            var scalars = line.filter { $0.value != 0 }
            while scalars.last == " " { scalars.removeLast() }
            return String(String.UnicodeScalarView(scalars))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    mutating func feed(_ data: Data) {
        pending.append(contentsOf: data)
        var index = 0
        while index < pending.count {
            let byte = pending[index]
            let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if index + length > pending.count { break } // a character split across two reads
            let scalar: Unicode.Scalar
            if byte < 0x80 {
                scalar = Unicode.Scalar(byte)
            } else {
                scalar = String(decoding: pending[index..<index + length], as: UTF8.self).unicodeScalars.first ?? "\u{FFFD}"
            }
            index += length
            put(scalar)
        }
        pending.removeFirst(index)
    }

    // MARK: Parser

    private mutating func put(_ scalar: Unicode.Scalar) {
        switch state {
        case .ground:
            switch scalar {
            case "\u{1B}": state = .escape
            case "\r": column = 0
            case "\n", "\u{0B}", "\u{0C}": lineFeed()
            case "\u{8}": column = max(0, min(column, columns - 1) - 1)
            case "\t": column = min(columns - 1, (column / 8 + 1) * 8)
            default: if scalar.value >= 0x20, scalar.value != 0x7F { write(scalar) }
            }
        case .escape:
            state = .ground
            switch scalar {
            case "[": state = .csi; params = ""
            case "]": state = .osc
            case "(", ")", "#", "%": state = .skipOne
            case "7": saved = (row, column)
            case "8": (row, column) = saved
            case "M": row = max(0, row - 1)
            case "c": grid = Self.blankGrid(columns: columns, rows: rows); row = 0; column = 0
            default: break
            }
        case .csi:
            switch scalar.value {
            case 0x20...0x3F: params.unicodeScalars.append(scalar)
            case 0x40...0x7E: state = .ground; applyCSI(Character(scalar))
            default: state = .ground
            }
        case .osc:
            if scalar == "\u{07}" { state = .ground } else if scalar == "\u{1B}" { state = .oscEscape }
        case .oscEscape:
            state = .ground
        case .skipOne:
            state = .ground
        }
    }

    private mutating func applyCSI(_ command: Character) {
        if params.hasPrefix("?") {
            guard "hl".contains(command) else { return }
            let on = command == "h"
            if params.dropFirst().split(separator: ";").contains(where: { ["47", "1047", "1049"].contains($0) }) {
                setAlternate(on)
            }
            return
        }
        // Private and intermediate forms (`>4;2m`, `=1u`, `2 q`) never move the cursor.
        guard params.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";") }) else { return }
        let limit = max(columns, rows)
        let values = params.split(separator: ";", omittingEmptySubsequences: false).prefix(2)
            .map { $0.isEmpty ? 0 : min(Int($0) ?? limit, limit) }
        let mode = values.first ?? 0
        let amount = max(1, mode)
        column = min(column, columns - 1)
        switch command {
        case "A": row = max(0, row - amount)
        case "B": row = min(rows - 1, row + amount)
        case "C": column = min(columns - 1, column + amount)
        case "D": column = max(0, column - amount)
        case "E": row = min(rows - 1, row + amount); column = 0
        case "F": row = max(0, row - amount); column = 0
        case "G": column = min(columns - 1, amount - 1)
        case "d": row = min(rows - 1, amount - 1)
        case "H", "f":
            row = min(rows - 1, amount - 1)
            column = min(columns - 1, max(1, values.dropFirst().first ?? 0) - 1)
        case "K":
            guard (0...2).contains(mode) else { return }
            clear(row, mode == 0 ? column : 0, mode == 1 ? column + 1 : columns)
        case "J":
            guard (0...2).contains(mode) else { return }
            if mode == 0 { clear(row, column, columns) }
            for line in (mode == 0 ? row + 1 : 0)..<(mode == 1 ? row : rows) { clear(line, 0, columns) }
            if mode == 1 { clear(row, 0, column + 1) }
        case "X": clear(row, column, column + amount)
        case "P":
            let end = min(columns, column + amount)
            grid[row].replaceSubrange(column..<end, with: [])
            grid[row].append(contentsOf: Array(repeating: " ", count: end - column))
        case "@":
            let end = min(columns, column + amount)
            grid[row].insert(contentsOf: Array(repeating: " ", count: end - column), at: column)
            grid[row].removeLast(end - column)
        case "L", "M":
            let count = min(amount, rows - row)
            if command == "L" {
                grid.removeLast(count)
                grid.insert(contentsOf: Array(repeating: Self.blankLine(columns), count: count), at: row)
            } else {
                grid.removeSubrange(row..<row + count)
                grid.append(contentsOf: Array(repeating: Self.blankLine(columns), count: count))
            }
        case "S": for _ in 0..<min(amount, rows) { scrollUp() }
        case "T":
            for _ in 0..<min(amount, rows) { grid.removeLast(); grid.insert(Self.blankLine(columns), at: 0) }
        case "s": saved = (row, column)
        case "u": (row, column) = saved
        default: break // m (colors), r (scroll region), h/l (modes), and the rest
        }
    }

    private mutating func setAlternate(_ on: Bool) {
        if on, savedMain == nil {
            savedMain = (grid, row, column)
            grid = Self.blankGrid(columns: columns, rows: rows)
            row = 0
            column = 0
        } else if !on, let main = savedMain {
            (grid, row, column) = main
            savedMain = nil
        }
    }

    // MARK: Cells

    private static func blankLine(_ columns: Int) -> [Unicode.Scalar] { Array(repeating: " ", count: columns) }
    private static func blankGrid(columns: Int, rows: Int) -> [[Unicode.Scalar]] {
        Array(repeating: blankLine(columns), count: rows)
    }

    private mutating func scrollUp() {
        grid.removeFirst()
        grid.append(Self.blankLine(columns))
    }

    private mutating func lineFeed() {
        column = 0
        if row == rows - 1 { scrollUp() } else { row += 1 }
    }

    /// Blanks cells `from..<to` of one row, and any wide glyph half left behind.
    private mutating func clear(_ line: Int, _ from: Int, _ to: Int) {
        let start = max(0, min(from, columns)), end = max(start, min(to, columns))
        guard start < end else { return }
        if start > 0, grid[line][start] == "\0" { grid[line][start - 1] = " " }
        if end < columns, grid[line][end] == "\0" { grid[line][end] = " " }
        for cell in start..<end { grid[line][cell] = " " }
    }

    private mutating func write(_ scalar: Unicode.Scalar) {
        let width = Self.width(scalar)
        guard width > 0 else { return } // combining marks and zero-width characters
        if column + width > columns { lineFeed() }
        clear(row, column, column + width)
        grid[row][column] = scalar
        if width == 2 { grid[row][column + 1] = "\0" }
        column += width
    }

    private static func width(_ scalar: Unicode.Scalar) -> Int {
        if scalar.value < 0x300 { return 1 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if scalar.properties.isEmojiPresentation { return 2 }
        return wide.contains { $0.contains(scalar.value) } ? 2 : 1
    }

    /// Wide and fullwidth glyphs take two cells; the usage bar's block characters take one.
    private static let wide: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
        0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F200...0x1F251, 0x20000...0x3FFFD,
    ]
}
