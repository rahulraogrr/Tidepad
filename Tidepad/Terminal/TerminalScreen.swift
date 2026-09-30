import Foundation

enum TerminalColor: Hashable, Sendable {
    case `default`
    /// 0–15 are the ANSI colours, 16–255 the xterm 256-colour palette.
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

struct TerminalAttributes: Hashable, Sendable {
    var foreground = TerminalColor.default
    var background = TerminalColor.default
    var bold = false, dim = false, italic = false, underline = false
    var inverse = false, hidden = false, strikethrough = false
}

/// A place between two cells: a line (numbered from the oldest line ever kept, so it doesn't change
/// as output scrolls) and a column boundary, 0 being before the first cell.
struct TerminalPosition: Comparable, Sendable {
    var line: Int
    var column: Int
    static func < (a: TerminalPosition, b: TerminalPosition) -> Bool { (a.line, a.column) < (b.line, b.column) }
}

/// Which mouse events the program asked for (xterm modes 1000, 1002 and 1003).
enum TerminalMouseTracking: Sendable { case none, clicks, drags, motion }

struct TerminalCell: Equatable, Sendable {
    /// Empty for the second half of a wide character.
    var character: String = " "
    var attributes = TerminalAttributes()
    /// Columns this cell's character takes: 1, 2 (wide), or 0 (covered by the wide character before it).
    var width: UInt8 = 1
}

/// The terminal emulator: turns the bytes a program writes (UTF-8 text and xterm control sequences)
/// into a grid of cells, as Terminal.app does. Foundation only, so it's tested without a window.
///
/// Supports what shells, git, less, vim and other full-screen programs use: cursor movement, erasing, inserting and
/// deleting, scroll regions, colours (16, 256 and 24-bit), text styles, the alternate screen, bracketed
/// paste, application cursor keys, window titles, status reports and mouse reporting.
final class TerminalScreen {
    private(set) var columns: Int
    private(set) var rows: Int
    /// The screen's lines: the main screen, or the alternate screen full-screen programs switch to.
    private var lines: [[TerminalCell]]
    private var savedMainLines: [[TerminalCell]]?
    /// Lines that scrolled off the top of the main screen, oldest first.
    private(set) var scrollback: [[TerminalCell]] = []
    var maximumScrollback = 5_000
    /// Scrollback lines discarded so far, so line numbers stay stable (see TerminalPosition).
    private(set) var droppedLines = 0

    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    /// Set after writing in the last column: the next character wraps first.
    private var pendingWrap = false
    private(set) var cursorVisible = true
    private(set) var applicationCursorKeys = false
    private(set) var bracketedPaste = false
    private(set) var mouseTracking = TerminalMouseTracking.none
    /// Mouse reports in the SGR format (mode 1006), which has no coordinate limit.
    private(set) var sgrMouse = false
    private var autoWrap = true
    private var insertMode = false
    private var attributes = TerminalAttributes()
    private var scrollTop = 0
    private var scrollBottom: Int
    private var savedCursor: (row: Int, column: Int, attributes: TerminalAttributes)?
    private var lastPrinted: String?
    private(set) var title = ""
    var isAlternateScreen: Bool { savedMainLines != nil }

    /// Replies to the program (status and device reports), to be written back to it.
    var respond: (([UInt8]) -> Void)?
    var bell: (() -> Void)?

    // Parser state.
    private enum State { case ground, escape, escapeIntermediate, csi, string, stringEscape }
    private var state = State.ground
    private var parameters: [UInt8] = []
    private var privateMarker: UInt8 = 0
    private var intermediate: UInt8 = 0
    private var stringKind: UInt8 = 0
    private var stringBytes: [UInt8] = []
    private var utf8: [UInt8] = []
    private var utf8Expected = 0

    init(columns: Int = 80, rows: Int = 24) {
        self.columns = max(2, columns)
        self.rows = max(1, rows)
        scrollBottom = self.rows - 1
        lines = Array(repeating: Array(repeating: TerminalCell(), count: max(2, columns)), count: max(1, rows))
    }

    // MARK: Reading the screen

    /// A row as shown with the view scrolled back `offset` lines into the scrollback.
    func row(_ index: Int, scrolledBack offset: Int = 0) -> [TerminalCell] {
        let offset = isAlternateScreen ? 0 : min(max(0, offset), scrollback.count)
        let absolute = scrollback.count - offset + index
        if absolute < scrollback.count { return scrollback[absolute] }
        let line = absolute - scrollback.count
        return line < lines.count ? lines[line] : []
    }

    /// A row's text, without trailing spaces (for checks and copying).
    func text(ofRow index: Int, scrolledBack offset: Int = 0) -> String {
        var text = row(index, scrolledBack: offset).map(\.character).joined()
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    /// The stable number of a row as shown with the view scrolled back `offset` lines.
    func lineNumber(ofRow row: Int, scrolledBack offset: Int = 0) -> Int {
        let offset = isAlternateScreen ? 0 : min(max(0, offset), scrollback.count)
        return droppedLines + (isAlternateScreen ? 0 : scrollback.count - offset) + row
    }

    /// The numbers of the first and last lines that can be shown.
    var lineNumbers: ClosedRange<Int> { droppedLines...(lineNumber(ofRow: rows - 1)) }

    /// A line by its stable number; empty if it's gone.
    func line(number: Int) -> [TerminalCell] {
        var index = number - droppedLines
        guard index >= 0 else { return [] }
        if !isAlternateScreen {
            if index < scrollback.count { return scrollback[index] }
            index -= scrollback.count
        }
        return index < lines.count ? lines[index] : []
    }

    /// The text between two positions, with lines joined by newlines and trailing spaces removed.
    func text(from start: TerminalPosition, to end: TerminalPosition) -> String {
        let (first, last) = start <= end ? (start, end) : (end, start)
        var result: [String] = []
        for number in first.line...last.line {
            let cells = line(number: number)
            let from = number == first.line ? min(first.column, cells.count) : 0
            let to = number == last.line ? min(last.column, cells.count) : cells.count
            var text = from < to ? cells[from..<to].filter { $0.width != 0 }.map(\.character).joined() : ""
            while text.hasSuffix(" ") { text.removeLast() }
            result.append(text)
        }
        return result.joined(separator: "\n")
    }

    /// The word around a position, for double-click: letters, digits and the characters of paths
    /// and URLs, so ~/src/App.swift or https://example.com/a?b=1 select whole.
    func word(at position: TerminalPosition) -> (start: TerminalPosition, end: TerminalPosition) {
        let cells = line(number: position.line)
        func isWordCharacter(_ index: Int) -> Bool {
            guard index >= 0 && index < cells.count else { return false }
            let character = cells[index].width == 0 && index > 0 ? cells[index - 1].character : cells[index].character
            guard let scalar = character.unicodeScalars.first, !character.isEmpty else { return false }
            if CharacterSet.alphanumerics.contains(scalar) { return true }
            return "/._-~:@?=&%+#$!*".unicodeScalars.contains(scalar)
        }
        let column = min(max(0, position.column), max(0, cells.count - 1))
        guard isWordCharacter(column) else {
            return (TerminalPosition(line: position.line, column: column), TerminalPosition(line: position.line, column: column + 1))
        }
        var start = column, end = column + 1
        while isWordCharacter(start - 1) { start -= 1 }
        while isWordCharacter(end) { end += 1 }
        return (TerminalPosition(line: position.line, column: start), TerminalPosition(line: position.line, column: end))
    }

    // MARK: Input

    func feed(_ data: Data) { feed(Array(data)) }
    func feed(_ string: String) { feed(Array(string.utf8)) }

    func feed(_ bytes: [UInt8]) {
        for byte in bytes { consume(byte) }
    }

    private func consume(_ byte: UInt8) {
        // Control characters act in any state (except inside strings), as in xterm.
        if byte < 0x20 || byte == 0x7F {
            if state == .string || state == .stringEscape {
                if byte == 0x07 { finishString(); return }
                if byte == 0x1B { state = .stringEscape; return }
                return
            }
            if byte == 0x1B { utf8 = []; state = .escape; intermediate = 0; return }
            if byte == 0x18 || byte == 0x1A { state = .ground; return } // CAN, SUB cancel a sequence.
            control(byte)
            return
        }
        switch state {
        case .ground: printable(byte)
        case .escape: escape(byte)
        case .escapeIntermediate:
            // ESC ( B and similar choose character sets; only the default one is supported.
            state = .ground
        case .csi: csi(byte)
        case .string: stringBytes.append(byte)
        case .stringEscape:
            if byte == 0x5C { finishString() } else { state = .string; stringBytes.append(byte) }
        }
    }

    private func printable(_ byte: UInt8) {
        if byte < 0x80 {
            utf8 = []
            print(Unicode.Scalar(byte))
            return
        }
        if byte & 0xC0 == 0x80 {
            guard !utf8.isEmpty else { print("\u{FFFD}"); return }
            utf8.append(byte)
            if utf8.count == utf8Expected {
                let decoded = String(decoding: utf8, as: UTF8.self)
                utf8 = []
                for scalar in decoded.unicodeScalars { print(scalar) }
            }
            return
        }
        if !utf8.isEmpty { print("\u{FFFD}") }
        utf8 = [byte]
        utf8Expected = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
    }

    // MARK: Printing

    private func print(_ scalar: Unicode.Scalar) {
        let width = Self.width(of: scalar)
        if width == 0 {
            // A combining mark joins the character before it.
            var column = pendingWrap ? cursorColumn : cursorColumn - 1
            if column >= 0, lines[cursorRow][column].width == 0, column > 0 { column -= 1 }
            if column >= 0 { lines[cursorRow][column].character.unicodeScalars.append(scalar) }
            return
        }
        if pendingWrap {
            if autoWrap { cursorColumn = 0; lineFeed() }
            pendingWrap = false
        }
        if width == 2 && cursorColumn == columns - 1 {
            // A wide character doesn't fit in the last column: it goes on the next line.
            if autoWrap { lines[cursorRow][cursorColumn] = blank(); cursorColumn = 0; lineFeed() } else { return }
        }
        if insertMode { insertCells(width) }
        clearWideCharacter(at: cursorColumn)
        let character = String(scalar)
        lines[cursorRow][cursorColumn] = TerminalCell(character: character, attributes: attributes, width: UInt8(width))
        if width == 2 {
            clearWideCharacter(at: cursorColumn + 1)
            lines[cursorRow][cursorColumn + 1] = TerminalCell(character: "", attributes: attributes, width: 0)
        }
        lastPrinted = character
        cursorColumn += width
        if cursorColumn >= columns {
            cursorColumn = columns - 1
            pendingWrap = true
        }
    }

    /// Overwriting half of a wide character blanks the other half.
    private func clearWideCharacter(at column: Int) {
        guard column < columns else { return }
        let cell = lines[cursorRow][column]
        if cell.width == 0 && column > 0 { lines[cursorRow][column - 1] = blank() }
        if cell.width == 2 && column + 1 < columns { lines[cursorRow][column + 1] = blank() }
    }

    /// Columns a character takes: 2 for East Asian wide characters and emoji, 0 for combining marks.
    static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x300 { return 1 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if (0xFE00...0xFE0F).contains(value) { return 0 } // Variation selectors.
        if scalar.properties.isEmojiPresentation { return 2 }
        let wide: [ClosedRange<UInt32>] = [
            0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
            0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD
        ]
        return wide.contains { $0.contains(value) } ? 2 : 1
    }

    private func blank() -> TerminalCell {
        var cell = TerminalCell()
        cell.attributes.background = attributes.background // Erased cells take the current background, as in xterm.
        return cell
    }

    private func blankLine() -> [TerminalCell] { Array(repeating: blank(), count: columns) }

    // MARK: Control characters

    private func control(_ byte: UInt8) {
        switch byte {
        case 0x07: bell?()
        case 0x08: // Backspace
            if cursorColumn > 0 { cursorColumn -= (pendingWrap ? 0 : 1) }
            pendingWrap = false
        case 0x09: // Tab: to the next multiple of 8.
            cursorColumn = min(columns - 1, (cursorColumn / 8 + 1) * 8)
            pendingWrap = false
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: cursorColumn = 0; pendingWrap = false
        default: break
        }
    }

    private func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom { scrollUp(1) }
        else if cursorRow < rows - 1 { cursorRow += 1 }
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursorRow == scrollTop { scrollDown(1) }
        else if cursorRow > 0 { cursorRow -= 1 }
    }

    private func scrollUp(_ count: Int) {
        for _ in 0..<min(count, scrollBottom - scrollTop + 1) {
            let removed = lines.remove(at: scrollTop)
            lines.insert(blankLine(), at: scrollBottom)
            // Lines leaving the top of the whole main screen are kept for scrolling back.
            if scrollTop == 0 && !isAlternateScreen {
                scrollback.append(removed)
                trimScrollback()
            }
        }
    }

    private func trimScrollback() {
        guard scrollback.count > maximumScrollback else { return }
        let excess = scrollback.count - maximumScrollback
        scrollback.removeFirst(excess)
        droppedLines += excess
    }

    private func scrollDown(_ count: Int) {
        for _ in 0..<min(count, scrollBottom - scrollTop + 1) {
            lines.remove(at: scrollBottom)
            lines.insert(blankLine(), at: scrollTop)
        }
    }

    // MARK: Escape sequences

    private func escape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case 0x5B: state = .csi; parameters = []; privateMarker = 0; intermediate = 0 // [
        case 0x5D, 0x50, 0x5E, 0x5F: state = .string; stringKind = byte; stringBytes = [] // ] P ^ _
        case 0x28, 0x29, 0x2A, 0x2B, 0x23, 0x25, 0x20: state = .escapeIntermediate // ( ) * + # % space
        case 0x37: saveCursor() // 7
        case 0x38: restoreCursor() // 8
        case 0x44: lineFeed() // D: index
        case 0x45: cursorColumn = 0; lineFeed() // E: next line
        case 0x4D: reverseIndex() // M
        case 0x63: reset() // c
        default: break // = > (keypad modes) and others.
        }
    }

    private func finishString() {
        state = .ground
        guard stringKind == 0x5D else { return } // Only OSC is used; DCS, PM and APC are ignored.
        let text = String(decoding: stringBytes, as: UTF8.self)
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0] == "0" || parts[0] == "2" { title = String(parts[1]) }
    }

    private func csi(_ byte: UInt8) {
        switch byte {
        case 0x30...0x3B: parameters.append(byte) // digits ; :
        case 0x3C...0x3F:
            if parameters.isEmpty { privateMarker = byte } // < = > ?
        case 0x20...0x2F: intermediate = byte
        case 0x40...0x7E:
            state = .ground
            dispatchCSI(byte)
        default: state = .ground
        }
    }

    /// The parameters, split at `;`. Each keeps its `:` sub-parameters.
    private func parsedParameters() -> [[Int?]] {
        guard !parameters.isEmpty else { return [] }
        return parameters.split(separator: 0x3B, omittingEmptySubsequences: false).map { group in
            group.split(separator: 0x3A, omittingEmptySubsequences: false).map { digits in
                digits.isEmpty ? nil : Int(String(decoding: digits, as: UTF8.self))
            }
        }
    }

    private func dispatchCSI(_ final: UInt8) {
        let groups = parsedParameters()
        let values = groups.map { $0.first ?? nil }
        func value(_ index: Int, _ fallback: Int) -> Int {
            index < values.count ? (values[index].map { $0 == 0 ? fallback : $0 } ?? fallback) : fallback
        }
        let n = value(0, 1)
        if privateMarker == 0x3F { // ?
            if final == 0x68 || final == 0x6C { setPrivateModes(values.compactMap { $0 }, on: final == 0x68) }
            return
        }
        if privateMarker == 0x3E { // >
            if final == 0x63 { respond?(Array("\u{1B}[>0;0;0c".utf8)) } // Secondary device attributes.
            return
        }
        if intermediate != 0 {
            if intermediate == 0x21 && final == 0x70 { softReset() } // CSI ! p
            return // e.g. CSI SP q (cursor shape).
        }
        switch final {
        case 0x40: insertCells(n) // @
        case 0x41: moveCursor(row: cursorRow - n, column: cursorColumn, clampToRegion: true) // A
        case 0x42: moveCursor(row: cursorRow + n, column: cursorColumn, clampToRegion: true) // B
        case 0x43: moveCursor(row: cursorRow, column: cursorColumn + n) // C
        case 0x44: moveCursor(row: cursorRow, column: cursorColumn - n) // D
        case 0x45: moveCursor(row: cursorRow + n, column: 0, clampToRegion: true) // E
        case 0x46: moveCursor(row: cursorRow - n, column: 0, clampToRegion: true) // F
        case 0x47, 0x60: moveCursor(row: cursorRow, column: n - 1) // G `
        case 0x48, 0x66: moveCursor(row: value(0, 1) - 1, column: value(1, 1) - 1) // H f
        case 0x49: for _ in 0..<n { control(0x09) } // I
        case 0x4A: eraseDisplay(values.first.flatMap { $0 } ?? 0) // J
        case 0x4B: eraseLine(values.first.flatMap { $0 } ?? 0) // K
        case 0x4C: insertLines(n) // L
        case 0x4D: deleteLines(n) // M
        case 0x50: deleteCells(n) // P
        case 0x53: scrollUp(n) // S
        case 0x54: scrollDown(n) // T
        case 0x58: eraseCells(n) // X
        case 0x5A: // Z: back tab
            for _ in 0..<n { cursorColumn = max(0, (cursorColumn - 1) / 8 * 8) }
            pendingWrap = false
        case 0x61: moveCursor(row: cursorRow, column: cursorColumn + n) // a
        case 0x62: // b: repeat the last character
            if let lastPrinted { for _ in 0..<min(n, columns * rows) { for scalar in lastPrinted.unicodeScalars { print(scalar) } } }
        case 0x63: respond?(Array("\u{1B}[?1;2c".utf8)) // c: "a VT100 with advanced video", like xterm.
        case 0x64: moveCursor(row: n - 1, column: cursorColumn) // d
        case 0x65: moveCursor(row: cursorRow + n, column: cursorColumn) // e
        case 0x68, 0x6C: if values.contains(4) { insertMode = final == 0x68 } // h l: insert mode
        case 0x6D: selectGraphicRendition(groups) // m
        case 0x6E: // n: status reports
            if value(0, 0) == 5 { respond?(Array("\u{1B}[0n".utf8)) }
            if value(0, 0) == 6 { respond?(Array("\u{1B}[\(cursorRow + 1);\(cursorColumn + 1)R".utf8)) }
        case 0x72: // r: scroll region
            let top = value(0, 1) - 1, bottom = value(1, rows) - 1
            if top < bottom && bottom < rows { scrollTop = top; scrollBottom = bottom }
            else { scrollTop = 0; scrollBottom = rows - 1 }
            moveCursor(row: 0, column: 0)
        case 0x73: saveCursor() // s
        case 0x75: restoreCursor() // u
        default: break
        }
    }

    private func setPrivateModes(_ modes: [Int], on: Bool) {
        for mode in modes {
            switch mode {
            case 1: applicationCursorKeys = on
            case 7: autoWrap = on
            case 25: cursorVisible = on
            case 47, 1047: switchScreen(alternate: on, saveCursor: false)
            case 1048: on ? saveCursor() : restoreCursor()
            case 1049: switchScreen(alternate: on, saveCursor: true)
            case 1000: mouseTracking = on ? .clicks : .none
            case 1002: mouseTracking = on ? .drags : .none
            case 1003: mouseTracking = on ? .motion : .none
            case 1006: sgrMouse = on
            case 2004: bracketedPaste = on
            default: break // Focus events and synchronised output aren't needed.
            }
        }
    }

    private func switchScreen(alternate: Bool, saveCursor save: Bool) {
        guard alternate != isAlternateScreen else { return }
        if alternate {
            if save { saveCursor() }
            savedMainLines = lines
            lines = Array(repeating: blankLine(), count: rows)
        } else {
            if let main = savedMainLines { lines = main }
            savedMainLines = nil
            if save { restoreCursor() }
        }
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
    }

    private func selectGraphicRendition(_ groups: [[Int?]]) {
        if groups.isEmpty { attributes = TerminalAttributes(); return }
        var index = 0
        func color(_ group: [Int?]) -> TerminalColor? {
            // 38;5;n  38;2;r;g;b  or the colon forms 38:5:n  38:2::r:g:b
            if group.count > 1 {
                let values = group.dropFirst().map { $0 ?? 0 }
                if values.first == 5, values.count >= 2 { return .indexed(UInt8(clamping: values[1])) }
                if values.first == 2 {
                    let rgb = values.count >= 5 ? Array(values[2...4]) : Array(values.dropFirst().prefix(3))
                    if rgb.count == 3 { return .rgb(UInt8(clamping: rgb[0]), UInt8(clamping: rgb[1]), UInt8(clamping: rgb[2])) }
                }
                return nil
            }
            let kind = index + 1 < groups.count ? groups[index + 1].first ?? nil : nil
            if kind == 5, index + 2 < groups.count {
                index += 2
                return .indexed(UInt8(clamping: groups[index].first.flatMap { $0 } ?? 0))
            }
            if kind == 2, index + 4 < groups.count {
                let rgb = (1...3).map { UInt8(clamping: groups[index + 1 + $0].first.flatMap { $0 } ?? 0) }
                index += 4
                return .rgb(rgb[0], rgb[1], rgb[2])
            }
            return nil
        }
        while index < groups.count {
            let group = groups[index]
            switch group.first.flatMap({ $0 }) ?? 0 {
            case 0: attributes = TerminalAttributes()
            case 1: attributes.bold = true
            case 2: attributes.dim = true
            case 3: attributes.italic = true
            case 4: attributes.underline = (group.count > 1 ? group[1] ?? 1 : 1) != 0
            case 7: attributes.inverse = true
            case 8: attributes.hidden = true
            case 9: attributes.strikethrough = true
            case 21: attributes.underline = true
            case 22: attributes.bold = false; attributes.dim = false
            case 23: attributes.italic = false
            case 24: attributes.underline = false
            case 27: attributes.inverse = false
            case 28: attributes.hidden = false
            case 29: attributes.strikethrough = false
            case let code where (30...37).contains(code): attributes.foreground = .indexed(UInt8(code - 30))
            case 38: if let chosen = color(group) { attributes.foreground = chosen }
            case 39: attributes.foreground = .default
            case let code where (40...47).contains(code): attributes.background = .indexed(UInt8(code - 40))
            case 48: if let chosen = color(group) { attributes.background = chosen }
            case 49: attributes.background = .default
            case let code where (90...97).contains(code): attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case let code where (100...107).contains(code): attributes.background = .indexed(UInt8(code - 100 + 8))
            default: break // Blinking, fonts, underline colours.
            }
            index += 1
        }
    }

    // MARK: Editing the screen

    private func moveCursor(row: Int, column: Int, clampToRegion: Bool = false) {
        var top = 0, bottom = rows - 1
        if clampToRegion && cursorRow >= scrollTop && cursorRow <= scrollBottom { top = scrollTop; bottom = scrollBottom }
        cursorRow = min(max(row, top), bottom)
        cursorColumn = min(max(column, 0), columns - 1)
        pendingWrap = false
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            for row in (cursorRow + 1)..<max(cursorRow + 1, rows) { lines[row] = blankLine() }
        case 1:
            eraseLine(1)
            for row in 0..<cursorRow { lines[row] = blankLine() }
        case 2: for row in 0..<rows { lines[row] = blankLine() }
        case 3: droppedLines += scrollback.count; scrollback = []
        default: break
        }
        pendingWrap = false
    }

    private func eraseLine(_ mode: Int) {
        let range: Range<Int>
        switch mode {
        case 0: range = cursorColumn..<columns
        case 1: range = 0..<(cursorColumn + 1)
        default: range = 0..<columns
        }
        for column in range { lines[cursorRow][column] = blank() }
        pendingWrap = false
    }

    private func eraseCells(_ count: Int) {
        for column in cursorColumn..<min(columns, cursorColumn + count) { lines[cursorRow][column] = blank() }
        pendingWrap = false
    }

    private func insertCells(_ count: Int) {
        let count = min(count, columns - cursorColumn)
        lines[cursorRow].insert(contentsOf: Array(repeating: blank(), count: count), at: cursorColumn)
        lines[cursorRow].removeLast(count)
        pendingWrap = false
    }

    private func deleteCells(_ count: Int) {
        let count = min(count, columns - cursorColumn)
        lines[cursorRow].removeSubrange(cursorColumn..<(cursorColumn + count))
        lines[cursorRow].append(contentsOf: Array(repeating: blank(), count: count))
        pendingWrap = false
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            lines.remove(at: scrollBottom)
            lines.insert(blankLine(), at: cursorRow)
        }
        cursorColumn = 0
        pendingWrap = false
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            lines.remove(at: cursorRow)
            lines.insert(blankLine(), at: scrollBottom)
        }
        cursorColumn = 0
        pendingWrap = false
    }

    private func saveCursor() { savedCursor = (cursorRow, cursorColumn, attributes) }

    private func restoreCursor() {
        guard let saved = savedCursor else { moveCursor(row: 0, column: 0); return }
        moveCursor(row: saved.row, column: saved.column)
        attributes = saved.attributes
    }

    private func softReset() {
        attributes = TerminalAttributes()
        cursorVisible = true
        applicationCursorKeys = false
        mouseTracking = .none
        sgrMouse = false
        insertMode = false
        autoWrap = true
        scrollTop = 0
        scrollBottom = rows - 1
        savedCursor = nil
    }

    /// Back to the state of a new terminal, keeping the scrollback.
    func reset() {
        if isAlternateScreen { switchScreen(alternate: false, saveCursor: false) }
        softReset()
        bracketedPaste = false
        lines = Array(repeating: blankLine(), count: rows)
        cursorRow = 0
        cursorColumn = 0
        pendingWrap = false
        title = ""
        state = .ground
    }

    /// Clears the screen and the scrollback, as ⌘K does in Terminal.app, keeping the cursor's line.
    func clear() {
        let current = lines[cursorRow]
        droppedLines += scrollback.count
        scrollback = []
        lines = Array(repeating: blankLine(), count: rows)
        lines[0] = current
        cursorRow = 0
    }

    // MARK: Size

    /// Changes the size. Lines keep their text (cut or padded); when the screen gets shorter, lines
    /// above the cursor move into the scrollback so the cursor's line stays visible.
    func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(2, newColumns), newRows = max(1, newRows)
        guard newColumns != columns || newRows != rows else { return }
        func fit(_ line: [TerminalCell]) -> [TerminalCell] {
            var line = line
            if line.count > newColumns {
                line.removeLast(line.count - newColumns)
                if line.last?.width == 2 { line[newColumns - 1] = TerminalCell() } // Don't keep half a wide character.
            } else if line.count < newColumns {
                line.append(contentsOf: Array(repeating: TerminalCell(), count: newColumns - line.count))
            }
            return line
        }
        columns = newColumns
        lines = lines.map(fit)
        savedMainLines = savedMainLines?.map(fit)
        if newRows < rows {
            // Drop blank lines at the bottom first, then move lines off the top.
            var excess = rows - newRows
            while excess > 0, lines.count - 1 > cursorRow, lines.last?.allSatisfy({ $0 == TerminalCell() }) == true {
                lines.removeLast(); excess -= 1
            }
            if excess > 0 {
                let removed = lines.prefix(excess)
                if !isAlternateScreen { scrollback.append(contentsOf: removed); trimScrollback() }
                lines.removeFirst(excess)
                cursorRow = max(0, cursorRow - excess)
            }
            savedMainLines = savedMainLines.map { Array($0.suffix(newRows)) }
        } else if newRows > rows {
            let extra = newRows - rows
            lines.append(contentsOf: Array(repeating: Array(repeating: TerminalCell(), count: newColumns), count: extra))
            savedMainLines?.append(contentsOf: Array(repeating: Array(repeating: TerminalCell(), count: newColumns), count: extra))
        }
        rows = newRows
        scrollTop = 0
        scrollBottom = rows - 1
        cursorRow = min(cursorRow, rows - 1)
        cursorColumn = min(cursorColumn, columns - 1)
        pendingWrap = false
    }
}
