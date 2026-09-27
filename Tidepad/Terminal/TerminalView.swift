import AppKit

/// Shows a TerminalScreen and sends what the user types to the shell. Text is drawn with Core Text
/// (through NSAttributedString) on a fixed grid, and keyboard input goes through NSTextInputClient,
/// Apple's text-input protocol, so dead keys and input methods work as in any Mac text view.
@MainActor final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    let screen: TerminalScreen
    /// Bytes for the shell: typed text, control keys, pasted text.
    var send: (([UInt8]) -> Void)?
    /// The grid's new size in columns and rows.
    var sizeChanged: ((_ columns: Int, _ rows: Int) -> Void)?
    var terminalFont: NSFont { didSet { measure(); fitGrid(); needsDisplay = true } }
    /// Take keyboard focus as soon as the view is in a window.
    var focusWhenShown = false

    private var boldFont: NSFont
    private var italicFont: NSFont
    private var cellWidth: CGFloat = 7
    private var cellHeight: CGFloat = 14
    private let inset: CGFloat = 4
    /// Lines scrolled back into the scrollback; 0 shows the live screen.
    private var scrollOffset = 0
    private var scrollRemainder: CGFloat = 0
    private var markedText = ""

    init(screen: TerminalScreen, font: NSFont) {
        self.screen = screen
        terminalFont = font
        boldFont = font
        italicFont = font
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        // Since macOS 14 views may draw outside their bounds; keep the terminal inside its panel.
        clipsToBounds = true
        measure()
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
    }

    required init?(coder: NSCoder) { fatalError("Not archivable") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusWhenShown, let window {
            focusWhenShown = false
            window.makeFirstResponder(self)
        }
    }

    // MARK: Size

    private func measure() {
        boldFont = NSFontManager.shared.convert(terminalFont, toHaveTrait: .boldFontMask)
        italicFont = NSFontManager.shared.convert(terminalFont, toHaveTrait: .italicFontMask)
        cellWidth = ("W" as NSString).size(withAttributes: [.font: terminalFont]).width
        cellHeight = ceil(terminalFont.ascender - terminalFont.descender + terminalFont.leading)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitGrid()
    }

    private func fitGrid() {
        let columns = max(2, Int((bounds.width - 2 * inset) / cellWidth))
        let rows = max(1, Int((bounds.height - 2 * inset) / cellHeight))
        guard columns != screen.columns || rows != screen.rows else { return }
        screen.resize(columns: columns, rows: rows)
        sizeChanged?(columns, rows)
        needsDisplay = true
    }

    /// The shell wrote something.
    func outputArrived() { needsDisplay = true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        TidepadTheme.editorBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        for row in 0..<screen.rows {
            let y = inset + CGFloat(row) * cellHeight
            guard NSRect(x: 0, y: y, width: bounds.width, height: cellHeight).intersects(dirtyRect) else { continue }
            draw(screen.row(row, scrolledBack: scrollOffset), y: y)
        }
        drawCursor()
    }

    private func draw(_ cells: [TerminalCell], y: CGFloat) {
        // Backgrounds first, in runs of the same colour.
        var column = 0
        while column < cells.count {
            let background = colors(for: cells[column].attributes).background
            var end = column + 1
            while end < cells.count && colors(for: cells[end].attributes).background == background { end += 1 }
            if let background {
                background.setFill()
                NSRect(x: x(column), y: y, width: CGFloat(end - column) * cellWidth, height: cellHeight).fill()
            }
            column = end
        }
        // Text: runs of plain ASCII with the same attributes are drawn together; other characters are
        // drawn one by one at their own column, so fallback fonts can't push the grid out of line.
        column = 0
        while column < cells.count {
            let cell = cells[column]
            if cell.width == 0 { column += 1; continue }
            if cell.character.utf8.count == 1 {
                var end = column + 1
                while end < cells.count && cells[end].attributes == cell.attributes && cells[end].width == 1
                        && cells[end].character.utf8.count == 1 { end += 1 }
                let text = cells[column..<end].map(\.character).joined()
                if text.contains(where: { $0 != " " }) || cell.attributes.underline || cell.attributes.strikethrough {
                    NSAttributedString(string: text, attributes: textAttributes(cell.attributes)).draw(at: NSPoint(x: x(column), y: y))
                }
                column = end
            } else {
                NSAttributedString(string: cell.character, attributes: textAttributes(cell.attributes)).draw(at: NSPoint(x: x(column), y: y))
                column += Int(max(1, cell.width))
            }
        }
    }

    private func drawCursor() {
        guard scrollOffset == 0 else { return }
        let rect = NSRect(x: x(screen.cursorColumn), y: inset + CGFloat(screen.cursorRow) * cellHeight, width: cellWidth, height: cellHeight)
        if !markedText.isEmpty {
            // Text being composed with an input method, underlined at the cursor.
            TidepadTheme.editorBackground.setFill()
            let width = (markedText as NSString).size(withAttributes: [.font: terminalFont]).width
            NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height).fill()
            NSAttributedString(string: markedText, attributes: [.font: terminalFont, .foregroundColor: TidepadTheme.editorText,
                                                                .underlineStyle: NSUnderlineStyle.single.rawValue]).draw(at: rect.origin)
            return
        }
        guard screen.cursorVisible else { return }
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        if focused {
            TidepadTheme.caret.withAlphaComponent(0.55).setFill()
            rect.fill()
        } else {
            TidepadTheme.caret.withAlphaComponent(0.7).setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    private func x(_ column: Int) -> CGFloat { inset + CGFloat(column) * cellWidth }

    private func textAttributes(_ attributes: TerminalAttributes) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: attributes.bold ? boldFont : attributes.italic ? italicFont : terminalFont,
            .foregroundColor: colors(for: attributes).foreground
        ]
        if attributes.underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if attributes.strikethrough { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return result
    }

    private func colors(for attributes: TerminalAttributes) -> (foreground: NSColor, background: NSColor?) {
        var foreground = color(attributes.foreground) ?? TidepadTheme.editorText
        var background = color(attributes.background)
        if attributes.inverse {
            let swapped = foreground
            foreground = background ?? TidepadTheme.editorBackground
            background = swapped
        }
        if attributes.dim { foreground = foreground.withAlphaComponent(0.6) }
        if attributes.hidden { foreground = background ?? TidepadTheme.editorBackground }
        return (foreground, background)
    }

    private func color(_ color: TerminalColor) -> NSColor? {
        switch color {
        case .default: return nil
        case .indexed(let index): return Self.palette[Int(index)]
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    /// The 16 ANSI colours (Terminal.app's "Basic" profile), the 6×6×6 colour cube and 24 greys.
    private static let palette: [NSColor] = {
        func rgb(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                    blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        var colors = [0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
                      0x818383, 0xFC391F, 0x31E722, 0xEAEC23, 0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB].map { rgb(UInt32($0)) }
        let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
        for red in steps { for green in steps { for blue in steps { colors.append(rgb(red << 16 | green << 8 | blue)) } } }
        for grey in 0..<24 { let value = UInt32(8 + grey * 10); colors.append(rgb(value << 16 | value << 8 | value)) }
        return colors
    }()

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !hasMarkedText() {
            if flags.contains(.command) {
                if event.charactersIgnoringModifiers == "k" { screen.clear(); scrollOffset = 0; needsDisplay = true; return }
                if let bytes = specialKey(event, flags) { typed(bytes) }
                return // Other ⌘ keys belong to menus.
            }
            if flags.contains(.control), let characters = event.charactersIgnoringModifiers, let code = Self.controlCode(characters) {
                typed([code])
                return
            }
            if let bytes = specialKey(event, flags) { typed(bytes); return }
        }
        interpretKeyEvents([event])
    }

    private func typed(_ bytes: [UInt8]) {
        scrollOffset = 0
        needsDisplay = true
        send?(bytes)
    }

    /// Ctrl-letter and the other control characters.
    private static func controlCode(_ characters: String) -> UInt8? {
        guard let scalar = characters.lowercased().unicodeScalars.first, characters.unicodeScalars.count == 1 else { return nil }
        switch scalar {
        case "a"..."z": return UInt8(scalar.value - 96)
        case "@", " ", "2": return 0
        case "[", "3": return 27
        case "\\", "4": return 28
        case "]", "5": return 29
        case "^", "6": return 30
        case "_", "-", "7", "/": return 31
        case "?", "8": return 127
        default: return nil
        }
    }

    /// Arrow, function and editing keys as xterm sends them.
    private func specialKey(_ event: NSEvent, _ flags: NSEvent.ModifierFlags) -> [UInt8]? {
        let escape = "\u{1B}"
        func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }
        if event.keyCode == 53 { return [0x1B] } // Escape
        guard let key = event.specialKey else { return nil }
        let option = flags.contains(.option), command = flags.contains(.command), shift = flags.contains(.shift)
        func arrow(_ letter: String) -> [UInt8] {
            if shift { return bytes("\(escape)[1;2\(letter)") }
            return bytes(screen.applicationCursorKeys ? "\(escape)O\(letter)" : "\(escape)[\(letter)")
        }
        switch key {
        case .upArrow: return arrow("A")
        case .downArrow: return arrow("B")
        case .rightArrow:
            if command { return [0x05] } // ⌘→: end of line (Ctrl-E)
            if option { return bytes("\(escape)f") } // ⌥→: next word
            return arrow("C")
        case .leftArrow:
            if command { return [0x01] } // ⌘←: start of line (Ctrl-A)
            if option { return bytes("\(escape)b") } // ⌥←: previous word
            return arrow("D")
        case .home: return bytes("\(escape)[H")
        case .end: return bytes("\(escape)[F")
        case .pageUp: return bytes("\(escape)[5~")
        case .pageDown: return bytes("\(escape)[6~")
        case .deleteForward: return bytes("\(escape)[3~")
        case .delete: // Backspace
            if command { return [0x15] } // ⌘⌫: delete to line start (Ctrl-U)
            if option { return [0x1B, 0x7F] } // ⌥⌫: delete the previous word
            return [0x7F]
        case .carriageReturn, .enter, .newline:
            return option || shift ? [0x1B, 0x0D] : [0x0D] // ⌥↩ / ⇧↩: a new line in Claude Code's prompt.
        case .tab: return [0x09]
        case .backTab: return bytes("\(escape)[Z")
        case .f1: return bytes("\(escape)OP")
        case .f2: return bytes("\(escape)OQ")
        case .f3: return bytes("\(escape)OR")
        case .f4: return bytes("\(escape)OS")
        case .f5: return bytes("\(escape)[15~")
        case .f6: return bytes("\(escape)[17~")
        case .f7: return bytes("\(escape)[18~")
        case .f8: return bytes("\(escape)[19~")
        case .f9: return bytes("\(escape)[20~")
        case .f10: return bytes("\(escape)[21~")
        case .f11: return bytes("\(escape)[23~")
        case .f12: return bytes("\(escape)[24~")
        default: return nil
        }
    }

    /// Edit > Paste. Line breaks are sent as Return; bracketed paste marks the text as pasted so
    /// shells and Claude Code don't run it line by line.
    @objc func paste(_ sender: Any?) {
        guard var text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if screen.bracketedPaste { text = "\u{1B}[200~" + text + "\u{1B}[201~" }
        typed(Array(text.utf8))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !screen.isAlternateScreen else { return }
        let lines = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY
        scrollRemainder += lines
        let whole = Int(scrollRemainder)
        scrollRemainder -= CGFloat(whole)
        let offset = min(max(0, scrollOffset + whole), screen.scrollback.count)
        if offset != scrollOffset { scrollOffset = offset; needsDisplay = true }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        typed(Array(text.utf8))
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)): typed([0x0D])
        case #selector(insertTab(_:)): typed([0x09])
        case #selector(deleteBackward(_:)): typed([0x7F])
        case #selector(cancelOperation(_:)): typed([0x1B])
        default: break // Other editing commands have no meaning in a terminal.
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where input method windows should appear: at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = NSRect(x: x(screen.cursorColumn), y: inset + CGFloat(screen.cursorRow) * cellHeight, width: cellWidth, height: cellHeight)
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
