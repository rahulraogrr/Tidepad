import Foundation

/// The terminal emulator (Foundation only): text, wrapping, colours, cursor movement, erasing,
/// scroll regions, the alternate screen, wide characters and replies to the program.
@main struct TerminalChecks {
    static func screen(_ input: String) -> TerminalScreen { screen(10, 4, input) }
    static func screen(_ columns: Int, _ rows: Int, _ input: String) -> TerminalScreen {
        let screen = TerminalScreen(columns: columns, rows: rows)
        screen.feed(input)
        return screen
    }
    static func texts(_ screen: TerminalScreen) -> [String] { (0..<screen.rows).map { screen.text(ofRow: $0) } }
    static let esc = "\u{1B}"

    static func main() {
        // Text, CR/LF, wrapping, scrolling into the scrollback.
        var s = screen("hello\r\nworld")
        precondition(texts(s) == ["hello", "world", "", ""] && s.cursorRow == 1 && s.cursorColumn == 5)
        s = screen("0123456789ab")
        precondition(texts(s) == ["0123456789", "ab", "", ""], "Wrap: \(texts(s))")
        s = screen("0123456789")
        precondition(s.cursorRow == 0 && s.cursorColumn == 9, "The last column waits to wrap")
        s.feed("\r\n")
        precondition(s.cursorRow == 1, "CR LF after a full line doesn't add a blank line")
        s = screen(10, 3, "1\r\n2\r\n3\r\n4\r\n5")
        precondition(texts(s) == ["3", "4", "5"] && s.scrollback.count == 2 && s.text(ofRow: 0, scrolledBack: 2) == "1")
        s = screen("a\tb\u{08}\u{08}c")
        precondition(s.text(ofRow: 0) == "a      cb", "Tab and backspace: \(s.text(ofRow: 0))")

        // Cursor movement and erasing.
        s = screen("\(esc)[3;4HX\(esc)[1;1HY\(esc)[2BZ\(esc)[A\(esc)[5GW")
        precondition(texts(s) == ["Y", "    W", " Z X", ""], "Cursor movement: \(texts(s))")
        s = screen("abcdefghij\(esc)[1;5H\(esc)[K")
        precondition(s.text(ofRow: 0) == "abcd", "Erase to end of line")
        s = screen("abcdefghij\(esc)[1;5H\(esc)[1K")
        precondition(s.text(ofRow: 0) == "     fghij", "Erase to start of line")
        s = screen("abc\r\ndef\r\nghi\(esc)[2;2H\(esc)[J")
        precondition(texts(s) == ["abc", "d", "", ""], "Erase below: \(texts(s))")
        s = screen("abc\r\ndef\(esc)[2J")
        precondition(texts(s) == ["", "", "", ""], "Erase screen")
        s = screen("abcdef\(esc)[1;2H\(esc)[2P")
        precondition(s.text(ofRow: 0) == "adef", "Delete characters")
        s = screen("abcdef\(esc)[1;2H\(esc)[2@")
        precondition(s.text(ofRow: 0) == "a  bcdef", "Insert characters")
        s = screen("abcdef\(esc)[1;2H\(esc)[3X")
        precondition(s.text(ofRow: 0) == "a   ef", "Erase characters")
        s = screen("1\r\n2\r\n3\r\n4\(esc)[2;1H\(esc)[L")
        precondition(texts(s) == ["1", "", "2", "3"], "Insert line: \(texts(s))")
        s = screen("1\r\n2\r\n3\r\n4\(esc)[2;1H\(esc)[M")
        precondition(texts(s) == ["1", "3", "4", ""], "Delete line: \(texts(s))")
        s = screen("x\(esc)[3b")
        precondition(s.text(ofRow: 0) == "xxxx", "Repeat")

        // Scroll regions (used by vim, less and status lines).
        s = screen(10, 4, "top\(esc)[2;3r\(esc)[2;1Ha\r\nb\r\nc\(esc)[4;1Hbottom")
        precondition(texts(s) == ["top", "b", "c", "bottom"] && s.scrollback.isEmpty, "Scroll region: \(texts(s))")
        s = screen(10, 4, "1\r\n2\r\n3\r\n4\(esc)M")
        precondition(texts(s) == ["1", "2", "3", "4"] && s.cursorRow == 2, "Reverse index moves up")
        s.feed("\(esc)[1;1H\(esc)M")
        precondition(texts(s) == ["", "1", "2", "3"], "Reverse index at the top scrolls down")

        // Colours and styles.
        s = screen("\(esc)[1;31mR\(esc)[0m\(esc)[38;5;208mO\(esc)[48;2;1;2;3mB\(esc)[38:2::4:5:6mC\(esc)[7;4mI\(esc)[m.")
        let cells = s.row(0)
        precondition(cells[0].attributes.bold && cells[0].attributes.foreground == .indexed(1), "Bold red")
        precondition(cells[1].attributes.foreground == .indexed(208) && !cells[1].attributes.bold, "256 colours")
        precondition(cells[2].attributes.background == .rgb(1, 2, 3), "24-bit background")
        precondition(cells[3].attributes.foreground == .rgb(4, 5, 6) && cells[3].attributes.background == .rgb(1, 2, 3), "Colon form")
        precondition(cells[4].attributes.inverse && cells[4].attributes.underline, "Inverse, underline")
        precondition(cells[5].attributes == TerminalAttributes(), "Reset")
        s = screen("\(esc)[92;103mx")
        precondition(s.row(0)[0].attributes.foreground == .indexed(10) && s.row(0)[0].attributes.background == .indexed(11), "Bright colours")
        s = screen("\(esc)[44m\(esc)[2K")
        precondition(s.row(0)[5].attributes.background == .indexed(4), "Erasing uses the current background")

        // Unicode: UTF-8 split across reads, wide characters, emoji, combining marks.
        s = TerminalScreen(columns: 10, rows: 2)
        let bytes = Array("café 中文".utf8)
        for byte in bytes { s.feed([byte]) }
        precondition(s.text(ofRow: 0) == "café 中文", "UTF-8 across reads: \(s.text(ofRow: 0))")
        precondition(s.row(0)[5].width == 2 && s.row(0)[6].width == 0 && s.cursorColumn == 9, "Wide characters take two columns")
        s = screen(4, 2, "ab中文")
        precondition(texts(s) == ["ab中", "文"], "A wide character that doesn't fit wraps: \(texts(s))")
        s = screen("e\u{301}😀x")
        precondition(s.row(0)[0].character == "e\u{301}" && s.row(0)[1].width == 2 && s.row(0)[3].character == "x", "Combining mark and emoji")
        s = screen("中\(esc)[1;2HX")
        precondition(s.text(ofRow: 0) == " X", "Overwriting half a wide character clears it")

        // The alternate screen keeps the main screen and scrollback aside.
        s = screen(10, 3, "shell$ vim\(esc)[?1049h\(esc)[Hfull screen")
        precondition(s.isAlternateScreen && texts(s) == ["full scree", "n", ""])
        s.feed("\(esc)[?1049l")
        precondition(!s.isAlternateScreen && texts(s) == ["shell$ vim", "", ""] && s.cursorColumn == 9, "Back to the shell: \(texts(s))")

        // Modes, titles and replies to the program.
        s = screen("\(esc)[?25l\(esc)[?1h\(esc)[?2004h\(esc)]0;my title\u{07}\(esc)]2;other\(esc)\\")
        precondition(!s.cursorVisible && s.applicationCursorKeys && s.bracketedPaste && s.title == "other")
        var replies: [String] = []
        s = TerminalScreen(columns: 10, rows: 4)
        s.respond = { replies.append(String(decoding: $0, as: UTF8.self)) }
        s.feed("ab\(esc)[6n\(esc)[5n\(esc)[c\(esc)[>c")
        precondition(replies == ["\(esc)[1;3R", "\(esc)[0n", "\(esc)[?1;2c", "\(esc)[>0;0;0c"], "Replies: \(replies)")
        s = screen("\(esc)[?2026h\(esc)[?1000h\(esc)P+q544e\(esc)\\\(esc)(Bok\(esc)[>1u\(esc)[?u")
        precondition(s.text(ofRow: 0) == "ok", "Unsupported sequences are skipped cleanly: \(s.text(ofRow: 0))")

        // Mouse modes the program asks for.
        s = screen("\(esc)[?1002h\(esc)[?1006h")
        precondition(s.mouseTracking == .drags && s.sgrMouse, "Mouse modes on")
        s.feed("\(esc)[?1002l\(esc)[?1006l")
        precondition(s.mouseTracking == .none && !s.sgrMouse, "Mouse modes off")
        s = screen("\(esc)[?1000h\(esc)c")
        precondition(s.mouseTracking == .none, "Reset turns mouse reporting off")

        // Stable line numbers and selected text, including after lines scroll away and are dropped.
        s = TerminalScreen(columns: 12, rows: 3)
        s.maximumScrollback = 2
        s.feed("one\r\ntwo words\r\nthree\r\nfour\r\nfive")
        precondition(s.droppedLines == 0 && s.scrollback.count == 2 && s.lineNumbers == 0...4, "Line numbers: \(s.lineNumbers)")
        precondition(s.lineNumber(ofRow: 0) == 2 && s.lineNumber(ofRow: 0, scrolledBack: 2) == 0)
        let selection = s.text(from: TerminalPosition(line: 1, column: 4), to: TerminalPosition(line: 3, column: 2))
        precondition(selection == "words\nthree\nfo", "Selected text: \(selection)")
        precondition(s.text(from: TerminalPosition(line: 3, column: 2), to: TerminalPosition(line: 1, column: 4)) == selection, "Either direction")
        s.feed("\r\nsix")
        precondition(s.droppedLines == 1 && s.lineNumbers == 1...5 && s.line(number: 0).isEmpty, "Dropped lines keep numbers")
        precondition(s.text(from: TerminalPosition(line: 1, column: 0), to: TerminalPosition(line: 1, column: 12)) == "two words", "Text by stable number")
        s = screen(60, 2, "open ~/src/App.swift or https://a.b/c?d=1 now")
        let path = s.word(at: TerminalPosition(line: 0, column: 9))
        precondition(s.text(from: path.start, to: path.end) == "~/src/App.swift", "Double-click a path")
        let url = s.word(at: TerminalPosition(line: 0, column: 25))
        precondition(s.text(from: url.start, to: url.end) == "https://a.b/c?d=1", "Double-click a URL")
        s = screen(10, 2, "中文 ab")
        let wide = s.word(at: TerminalPosition(line: 0, column: 1))
        precondition(s.text(from: wide.start, to: wide.end) == "中文", "Double-click wide characters")
        s = screen(10, 3, "a\r\nb\r\nc\r\nd")
        s.clear()
        precondition(s.scrollback.isEmpty && s.droppedLines == 1 && s.lineNumber(ofRow: 0) == 1, "Clearing keeps numbering")

        // Resizing keeps the cursor's line visible.
        s = screen(10, 4, "1\r\n2\r\n3\r\n4")
        s.resize(columns: 5, rows: 2)
        precondition(texts(s) == ["3", "4"] && s.scrollback.count == 2 && s.cursorRow == 1, "Shrink: \(texts(s))")
        s.resize(columns: 12, rows: 4)
        precondition(s.rows == 4 && s.columns == 12 && s.row(0).count == 12 && s.cursorRow == 1)
        s = screen(10, 4, "prompt")
        s.resize(columns: 10, rows: 2)
        precondition(texts(s) == ["prompt", ""] && s.scrollback.isEmpty, "Blank lines at the bottom go first")

        // Save/restore cursor, reset, clear.
        s = screen("\(esc)7\(esc)[3;3H\(esc)[31mx\(esc)8y")
        precondition(s.text(ofRow: 0) == "y" && s.row(0)[0].attributes.foreground == .default)
        s = screen(10, 2, "1\r\n2\r\n3")
        s.clear()
        precondition(s.scrollback.isEmpty && texts(s) == ["3", ""] && s.cursorRow == 0, "Clear")

        // What VoiceOver reads: rows as lines, offsets and cells, wide characters.
        s = screen(10, 3, "ab  \r\n中x")
        var a = TerminalAccessibilityText(screen: s)
        precondition(a.string == "ab\n中x\n" && a.rowStarts == [0, 3, 6] && a.length == 6, "Accessibility text: \(a.string.debugDescription)")
        precondition(a.range(ofRow: 0) == NSRange(location: 0, length: 3) && a.range(ofRow: 2) == NSRange(location: 6, length: 0))
        precondition(a.row(containing: 2) == 0 && a.row(containing: 3) == 1 && a.row(containing: 6) == 2)
        precondition(a.offset(row: 1, column: 0) == 3 && a.offset(row: 1, column: 2) == 4 && a.offset(row: 1, column: 1) == 4)
        precondition(a.offset(row: 1, column: 9) == 5 && a.offset(row: 7, column: 0) == 6)
        let first = a.cell(at: 3), after = a.cell(at: 4), end = a.cell(at: 5)
        precondition(first.row == 1 && first.column == 0 && after.column == 2 && end.column == 3, "Cells: \(first) \(after) \(end)")
        let rowCells = a.cells(of: a.range(ofRow: 0)), both = a.cells(of: NSRange(location: 1, length: 3))
        precondition(rowCells.start.row == 0 && rowCells.end.row == 0 && rowCells.end.column == 2, "A line with its line feed stays on its row: \(rowCells)")
        precondition(both.start.row == 0 && both.end.row == 1 && both.end.column == 2, "Across rows: \(both)")
        s = screen(10, 2, "1\r\n2\r\n3")
        a = TerminalAccessibilityText(screen: s, scrolledBack: 1)
        precondition(a.string == "1\n2", "Scrolled back: \(a.string.debugDescription)")

        // New output for VoiceOver: a command's output and prompt, not the echo of typed keys.
        s = screen(20, 4, "$ ")
        var tracker = TerminalOutputTracker()
        precondition(tracker.newOutput(in: s, afterTyping: false) == nil, "Nothing before the first look")
        s.feed("ls")
        precondition(tracker.newOutput(in: s, afterTyping: true) == nil, "Echo is skipped")
        s.feed("\r\nfile1  file2\r\n$ ")
        precondition(tracker.newOutput(in: s, afterTyping: true) == "file1  file2\n$", "Output and prompt")
        precondition(tracker.newOutput(in: s, afterTyping: false) == nil, "Read once")
        s.feed("done")
        precondition(tracker.newOutput(in: s, afterTyping: false) == "done", "Output on the prompt line")
        s.feed("\(esc)[?1049h\(esc)[Hvim")
        precondition(tracker.newOutput(in: s, afterTyping: false) == nil, "Full-screen programs aren't read")
        s.feed("\(esc)[?1049l")
        _ = tracker.newOutput(in: s, afterTyping: false)
        s.feed(String(repeating: "line\r\n", count: 100) + "end")
        let long = tracker.newOutput(in: s, afterTyping: false) ?? ""
        precondition(long.hasSuffix("end") && long.split(separator: "\n").count <= TerminalOutputTracker.maximumLines + 1, "Long output is read from its end")

        // Hostile or binary output: huge numbers, endless strings and floods are bounded, not a crash.
        let huge = String(repeating: "9", count: 40)
        for final in ["A", "B", "C", "D", "E", "F", "G", "H", "I", "Z", "L", "M", "P", "@", "X", "S", "T", "b", "d", "e", "a", "r"] {
            s = screen("x\(esc)[\(huge)\(final)\(esc)[\(huge);\(huge)\(final)y")
        }
        s = screen("\(esc)[9223372036854775807;9223372036854775807H\(esc)[9223372036854775807Cz")
        precondition(s.cursorRow == 3 && s.cursorColumn == 9, "Huge cursor positions are clamped")
        var clock = Date()
        s = screen(80, 24, "\(esc)[65535I\(esc)[65535Z\(esc)[999999999I")
        precondition(Date().timeIntervalSince(clock) < 0.1, "Tab counts are bounded by the width")
        s = screen("\(esc)[" + String(repeating: "1;", count: 100_000) + "m")
        precondition(s.text(ofRow: 0) == "", "A flood of parameters")
        s = screen("\(esc)]0;" + String(repeating: "t", count: 1_000_000) + "\u{07}after")
        precondition(s.title.count == TerminalScreen.titleLimit && s.text(ofRow: 0) == "after", "Long titles are cut, and the string still ends")
        s = screen("\(esc)]0;" + String(repeating: "t", count: 100_000) + "\(esc)\\x")
        precondition(s.title.count == TerminalScreen.titleLimit && s.text(ofRow: 0) == "x", "OSC ended by ESC \\")
        clock = Date()
        s = screen("e" + String(repeating: "\u{301}", count: 200_000) + "f")
        let marked = s.text(ofRow: 0)
        precondition(marked.unicodeScalars.count == TerminalScreen.marksPerCell + 1 && marked.hasSuffix("f"), "Combining marks per cell are capped")
        precondition(Date().timeIntervalSince(clock) < 2, "A flood of combining marks is quick")

        // Pasting: line breaks as Return, no control characters, so a paste can't end the bracketed
        // paste early and run commands.
        let pasted = TerminalScreen.pasteBytes("ls\r\nrm -rf x\u{1B}[201~\necho\u{03}\u{7F}\tend", bracketed: true)
        precondition(pasted == Array("\u{1B}[200~ls\rrm -rf x[201~\recho\tend\u{1B}[201~".utf8), "Bracketed paste: \(String(decoding: pasted, as: UTF8.self).debugDescription)")
        precondition(TerminalScreen.pasteBytes("a\nb", bracketed: false) == Array("a\rb".utf8), "Plain paste")
        precondition(TerminalScreen.pasteBytes("中文 ✓", bracketed: false) == Array("中文 ✓".utf8), "Non-ASCII is kept")

        // Throughput: 10 MB of coloured output.
        let line = "\(esc)[32mgreen\(esc)[0m plain text with some words 中文 \(esc)[1mbold\(esc)[0m\r\n"
        let chunk = Array(String(repeating: line, count: 1000).utf8)
        let big = TerminalScreen(columns: 120, rows: 40)
        let start = Date()
        var fed = 0
        while fed < 10_000_000 { big.feed(chunk); fed += chunk.count }
        let seconds = Date().timeIntervalSince(start)
        print(String(format: "Terminal checks passed: text, wrapping, cursor, erasing, scroll regions, colours, Unicode, alternate screen, modes, mouse modes, selection text and words, replies, resizing, VoiceOver text, new output, limits on hostile output and pasting. 10 MB of output in %.2f s.", seconds))
    }
}
