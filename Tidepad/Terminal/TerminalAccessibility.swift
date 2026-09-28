import Foundation

/// The terminal's visible text as VoiceOver reads it: one line per row, with trailing blanks trimmed,
/// and the mapping between character offsets (UTF-16 units, as NSAccessibility counts them) and grid
/// cells, so TerminalView can answer VoiceOver's questions about lines, ranges and their places on screen.
struct TerminalAccessibilityText {
    /// The rows' text, separated by line feeds.
    let string: String
    /// The offset where each row's text starts.
    let rowStarts: [Int]
    /// For each row, the column of each UTF-16 unit in its text.
    private let columns: [[Int]]
    /// For each row, the column just past its last non-blank cell.
    private let rowEnds: [Int]

    init(screen: TerminalScreen, scrolledBack offset: Int = 0) {
        var string = "", starts: [Int] = [], columns: [[Int]] = [], ends: [Int] = []
        var length = 0
        for row in 0..<screen.rows {
            if row > 0 { string += "\n"; length += 1 }
            starts.append(length)
            let cells = screen.row(row, scrolledBack: offset)
            var end = cells.count
            while end > 0 && cells[end - 1].character == " " && cells[end - 1].width == 1 { end -= 1 }
            var rowColumns: [Int] = []
            for column in 0..<end where cells[column].width != 0 {
                let character = cells[column].character
                string += character
                rowColumns += Array(repeating: column, count: character.utf16.count)
            }
            length += rowColumns.count
            columns.append(rowColumns)
            ends.append(end)
        }
        self.string = string
        rowStarts = starts
        self.columns = columns
        rowEnds = ends
    }

    var length: Int { (string as NSString).length }

    /// The row a character offset is on (an offset on a line feed belongs to the row it ends).
    func row(containing offset: Int) -> Int {
        var row = 0
        while row + 1 < rowStarts.count && rowStarts[row + 1] <= offset { row += 1 }
        return row
    }

    /// The characters of a row, including the line feed that ends it (as NSTextView counts lines).
    func range(ofRow row: Int) -> NSRange {
        guard rowStarts.indices.contains(row) else { return NSRange(location: NSNotFound, length: 0) }
        let breakLength = row + 1 < rowStarts.count ? 1 : 0
        return NSRange(location: rowStarts[row], length: columns[row].count + breakLength)
    }

    /// The offset of the first character at or after a cell; past the row's text, the row's end.
    func offset(row: Int, column: Int) -> Int {
        guard rowStarts.indices.contains(row) else { return row < 0 ? 0 : length }
        let index = columns[row].firstIndex { $0 >= column } ?? columns[row].count
        return rowStarts[row] + index
    }

    /// The cell a character offset is in; past a row's text, the cell after it.
    func cell(at offset: Int) -> (row: Int, column: Int) {
        let row = row(containing: offset)
        let index = offset - rowStarts[row]
        return (row, index < columns[row].count ? columns[row][index] : rowEnds[row])
    }

    /// The first cell of a range and the cell just past it. A range that ends with a row's line feed
    /// ends on that row, not at the start of the next one.
    func cells(of range: NSRange) -> (start: (row: Int, column: Int), end: (row: Int, column: Int)) {
        let start = cell(at: range.location)
        var end = cell(at: range.location + range.length)
        if range.length > 0 && end.row > start.row && rowStarts[end.row] == range.location + range.length {
            end = (end.row - 1, rowEnds[end.row - 1])
        }
        return (start, end)
    }
}

/// Finds the output that's new since the last look, so VoiceOver can read it as it arrives, as it
/// does in Terminal.app. What's new is the text from where the cursor was to where it is now, which
/// covers a command's output and the next prompt.
struct TerminalOutputTracker {
    private var mark: TerminalPosition?
    /// Output of more lines than this is read from its end.
    static let maximumLines = 40

    /// The cursor's place, as a stable position.
    private static func cursor(of screen: TerminalScreen) -> TerminalPosition {
        TerminalPosition(line: screen.lineNumber(ofRow: screen.cursorRow), column: screen.cursorColumn)
    }

    /// The text written since the last call, or nil if there's nothing to read. `afterTyping` means
    /// the user just typed: output on the same line is then the shell echoing the keys, which
    /// VoiceOver already speaks, so it's skipped. Full-screen programs (vim, less) redraw the whole
    /// screen, so their output isn't read this way; VoiceOver can read their screen instead.
    mutating func newOutput(in screen: TerminalScreen, afterTyping: Bool) -> String? {
        let cursor = Self.cursor(of: screen)
        defer { mark = cursor }
        guard let mark, !screen.isAlternateScreen, mark < cursor else { return nil }
        if afterTyping && mark.line == cursor.line { return nil }
        let first = max(mark, TerminalPosition(line: max(screen.droppedLines, cursor.line - Self.maximumLines), column: 0))
        let text = screen.text(from: first, to: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Forgets what came before, so only output after this is read.
    mutating func skip(in screen: TerminalScreen) { mark = Self.cursor(of: screen) }
}
