import AppKit

/// Shows a TerminalScreen and sends what the user types to the shell. Text is drawn with Core Text
/// (through NSAttributedString) on a fixed grid, and keyboard input goes through NSTextInputClient,
/// Apple's text-input protocol, so dead keys and input methods work as in any Mac text view.
///
/// The mouse selects text (drag, double-click for a word, triple-click for a line; ⌘C copies), unless
/// the program asked for mouse events, as vim and less can: then clicks, drags and the
/// scroll wheel go to the program, and holding ⌥ selects text instead, as in iTerm.
///
/// VoiceOver sees a text area, as in Terminal.app: it can read the visible lines, move through them
/// by line, word and character, and it reads a command's output as it arrives.
@MainActor final class TerminalView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
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
    /// The selection's fixed end and moving end; nil when nothing is selected.
    private var selectionAnchor: TerminalPosition?
    private var selectionHead: TerminalPosition?
    private var selectionWasAlternate = false
    /// Where Copy puts text (a private pasteboard in checks).
    var pasteboard = NSPasteboard.general
    /// The last cell reported to the program while dragging, so each cell is sent once.
    private var lastReportedCell: (column: Int, row: Int)?
    /// VoiceOver: what output is new, when the user last typed, and whether an update is on its way.
    private var outputTracker = TerminalOutputTracker()
    private var lastTyped = Date.distantPast
    private var accessibilityUpdatePending = false

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
    func outputArrived() {
        // A selection on the main screen doesn't apply to a full-screen program's screen, and back.
        if selectionAnchor != nil && selectionWasAlternate != screen.isAlternateScreen { clearSelection() }
        needsDisplay = true
        scheduleAccessibilityUpdate()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        TidepadTheme.editorBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        for row in 0..<screen.rows {
            let y = inset + CGFloat(row) * cellHeight
            guard NSRect(x: 0, y: y, width: bounds.width, height: cellHeight).intersects(dirtyRect) else { continue }
            let cells = screen.row(row, scrolledBack: scrollOffset)
            drawBackgrounds(cells, y: y)
            drawSelection(row: row, length: cells.count, y: y)
            drawText(cells, y: y)
        }
        drawCursor()
    }

    private var selection: (start: TerminalPosition, end: TerminalPosition)? {
        guard let anchor = selectionAnchor, let head = selectionHead, anchor != head else { return nil }
        return anchor < head ? (anchor, head) : (head, anchor)
    }

    private func drawSelection(row: Int, length: Int, y: CGFloat) {
        guard let selection else { return }
        let line = screen.lineNumber(ofRow: row, scrolledBack: scrollOffset)
        guard line >= selection.start.line && line <= selection.end.line else { return }
        let from = line == selection.start.line ? selection.start.column : 0
        let to = line == selection.end.line ? selection.end.column : screen.columns
        guard to > from else { return }
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        (focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        NSRect(x: x(from), y: y, width: CGFloat(to - from) * cellWidth, height: cellHeight).fill()
    }

    /// Cell backgrounds, in runs of the same colour.
    private func drawBackgrounds(_ cells: [TerminalCell], y: CGFloat) {
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
    }

    /// Text: runs of plain ASCII with the same attributes are drawn together; other characters are
    /// drawn one by one at their own column, so fallback fonts can't push the grid out of line.
    private func drawText(_ cells: [TerminalCell], y: CGFloat) {
        var column = 0
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
                if event.charactersIgnoringModifiers == "k" { clearTerminal(nil); return }
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
        lastTyped = Date()
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
            return option || shift ? [0x1B, 0x0D] : [0x0D] // ⌥↩ / ⇧↩: a new line in multi-line prompts.
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
    /// shells and other programs don't run it line by line. Control characters are removed
    /// (TerminalScreen.pasteBytes), so pasted text can't smuggle in keystrokes.
    @objc func paste(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        typed(TerminalScreen.pasteBytes(text, bracketed: screen.bracketedPaste))
    }

    // MARK: Mouse

    /// The program gets mouse events, unless ⌥ is held to select text instead.
    private func reportsMouse(_ event: NSEvent) -> Bool {
        screen.mouseTracking != .none && !event.modifierFlags.contains(.option)
    }

    /// The cell under the mouse (0-based, clamped to the grid).
    private func cell(for event: NSEvent) -> (column: Int, row: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let column = Int((point.x - inset) / cellWidth), row = Int((point.y - inset) / cellHeight)
        return (min(max(0, column), screen.columns - 1), min(max(0, row), screen.rows - 1))
    }

    /// The column boundary nearest the mouse, as a stable position.
    private func position(for event: NSEvent) -> TerminalPosition {
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(((point.x - inset) / cellWidth).rounded())
        let row = min(max(0, Int((point.y - inset) / cellHeight)), screen.rows - 1)
        return TerminalPosition(line: screen.lineNumber(ofRow: row, scrolledBack: scrollOffset), column: min(max(0, column), screen.columns))
    }

    /// Sends a mouse event to the program: button 0 left, 1 middle, 2 right, 3 none (motion), 64/65 wheel.
    private func report(_ event: NSEvent, button: Int, press: Bool, motion: Bool = false) {
        let cell = cell(for: event)
        var code = button + (motion ? 32 : 0)
        let flags = event.modifierFlags
        if flags.contains(.shift) { code += 4 }
        if flags.contains(.control) { code += 16 }
        if screen.sgrMouse {
            send?(Array("\u{1B}[<\(code);\(cell.column + 1);\(cell.row + 1)\(press ? "M" : "m")".utf8))
        } else if cell.column < 223 && cell.row < 223 {
            let value = press ? code : 3 + (code & ~3) // The old format reports every release as button 3.
            send?([0x1B, 0x5B, 0x4D, UInt8(32 + value), UInt8(33 + cell.column), UInt8(33 + cell.row)])
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportsMouse(event) {
            clearSelection()
            lastReportedCell = cell(for: event)
            report(event, button: 0, press: true)
            return
        }
        let position = position(for: event)
        switch event.clickCount {
        case 2:
            let word = screen.word(at: TerminalPosition(line: position.line, column: max(0, cell(for: event).column)))
            selectionAnchor = word.start
            selectionHead = word.end
        case 3...:
            selectionAnchor = TerminalPosition(line: position.line, column: 0)
            selectionHead = TerminalPosition(line: position.line, column: screen.columns)
        default:
            selectionAnchor = position
            selectionHead = position
        }
        selectionWasAlternate = screen.isAlternateScreen
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if reportsMouse(event) {
            guard screen.mouseTracking == .drags || screen.mouseTracking == .motion else { return }
            let cell = cell(for: event)
            if lastReportedCell?.column != cell.column || lastReportedCell?.row != cell.row {
                lastReportedCell = cell
                report(event, button: 0, press: true, motion: true)
            }
            return
        }
        guard selectionAnchor != nil else { return }
        // Dragging past the top or bottom scrolls through the scrollback.
        let point = convert(event.locationInWindow, from: nil)
        if point.y < 0 && scrollOffset < screen.scrollback.count && !screen.isAlternateScreen { scrollOffset += 1 }
        if point.y > bounds.height && scrollOffset > 0 { scrollOffset -= 1 }
        selectionHead = position(for: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if reportsMouse(event) {
            report(event, button: 0, press: false)
            lastReportedCell = nil
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportsMouse(event) { report(event, button: 2, press: true) } else { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if reportsMouse(event) { report(event, button: 2, press: false) } else { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if reportsMouse(event) { report(event, button: 1, press: true) } else { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if reportsMouse(event) { report(event, button: 1, press: false) } else { super.otherMouseUp(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard screen.mouseTracking == .motion, reportsMouse(event) else { return }
        let cell = cell(for: event)
        if lastReportedCell?.column != cell.column || lastReportedCell?.row != cell.row {
            lastReportedCell = cell
            report(event, button: 3, press: true, motion: true)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func scrollWheel(with event: NSEvent) {
        let lines = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY
        scrollRemainder += lines
        let whole = Int(scrollRemainder)
        scrollRemainder -= CGFloat(whole)
        guard whole != 0 else { return }
        if reportsMouse(event) {
            for _ in 0..<abs(whole) { report(event, button: whole > 0 ? 64 : 65, press: true) }
        } else if screen.isAlternateScreen {
            // Full-screen programs without mouse reporting (less, man) scroll with the arrow keys, as in Terminal.app.
            let key = whole > 0 ? "A" : "B"
            let sequence = screen.applicationCursorKeys ? "\u{1B}O\(key)" : "\u{1B}[\(key)"
            send?(Array(String(repeating: sequence, count: abs(whole)).utf8))
        } else {
            let offset = min(max(0, scrollOffset + whole), screen.scrollback.count)
            if offset != scrollOffset { scrollOffset = offset; needsDisplay = true }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Clear", action: #selector(clearTerminal(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: Selection

    /// Selects from one position to another (used by checks; the mouse does the same).
    func select(from start: TerminalPosition, to end: TerminalPosition) {
        selectionAnchor = start
        selectionHead = end
        selectionWasAlternate = screen.isAlternateScreen
        needsDisplay = true
    }

    var selectedText: String? {
        guard let selection else { return nil }
        return screen.text(from: selection.start, to: selection.end)
    }

    func clearSelection() {
        guard selectionAnchor != nil else { return }
        selectionAnchor = nil
        selectionHead = nil
        needsDisplay = true
    }

    /// Edit > Copy.
    @objc func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { NSSound.beep(); return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Edit > Select All: the scrollback and the screen.
    override func selectAll(_ sender: Any?) {
        select(from: TerminalPosition(line: screen.lineNumbers.lowerBound, column: 0),
               to: TerminalPosition(line: screen.lineNumbers.upperBound, column: screen.columns))
    }

    @objc func clearTerminal(_ sender: Any?) {
        screen.clear()
        scrollOffset = 0
        clearSelection()
        needsDisplay = true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return selection != nil }
        return true
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

    // MARK: Accessibility

    /// At most four times a second while output streams: tells VoiceOver the text changed, and has it
    /// read the new output (see TerminalOutputTracker).
    private func scheduleAccessibilityUpdate() {
        guard !accessibilityUpdatePending else { return }
        accessibilityUpdatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.updateAccessibility() }
        }
    }

    private func updateAccessibility() {
        accessibilityUpdatePending = false
        guard NSWorkspace.shared.isVoiceOverEnabled else { outputTracker.skip(in: screen); return }
        NSAccessibility.post(element: self, notification: .valueChanged)
        let typing = Date().timeIntervalSince(lastTyped) < 0.5
        guard let output = outputTracker.newOutput(in: screen, afterTyping: typing), let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: output, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// The visible text, as VoiceOver sees it.
    private var accessibilityText: TerminalAccessibilityText { TerminalAccessibilityText(screen: screen, scrolledBack: scrollOffset) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityValue() -> Any? { accessibilityText.string }
    override func accessibilityNumberOfCharacters() -> Int { accessibilityText.length }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: accessibilityText.length) }

    /// The selection, or else the cursor as the insertion point.
    override func accessibilitySelectedTextRange() -> NSRange {
        let text = accessibilityText
        let firstLine = screen.lineNumber(ofRow: 0, scrolledBack: scrollOffset)
        func offset(_ position: TerminalPosition) -> Int {
            text.offset(row: position.line - firstLine, column: position.column)
        }
        if let selection {
            let start = offset(selection.start), end = offset(selection.end)
            return NSRange(location: start, length: max(0, end - start))
        }
        guard scrollOffset == 0 else { return NSRange(location: 0, length: 0) }
        return NSRange(location: text.offset(row: screen.cursorRow, column: screen.cursorColumn), length: 0)
    }

    override func accessibilitySelectedText() -> String? {
        let range = accessibilitySelectedTextRange()
        return (accessibilityText.string as NSString).substring(with: range)
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        accessibilityText.row(containing: accessibilitySelectedTextRange().location)
    }

    override func accessibilityLine(for index: Int) -> Int { accessibilityText.row(containing: index) }
    override func accessibilityRange(forLine line: Int) -> NSRange { accessibilityText.range(ofRow: line) }

    override func accessibilityString(for range: NSRange) -> String? {
        let string = accessibilityText.string as NSString
        guard NSMaxRange(range) <= string.length else { return nil }
        return string.substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0, attributes: [.font: terminalFont]) }
    }

    /// The screen rectangle of a range: its cells on one row, or the full rows it spans.
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let text = accessibilityText
        let (start, end) = text.cells(of: range)
        var rect: NSRect
        if start.row == end.row {
            let width = CGFloat(max(1, end.column - start.column)) * cellWidth
            rect = NSRect(x: x(start.column), y: inset + CGFloat(start.row) * cellHeight, width: width, height: cellHeight)
        } else {
            rect = NSRect(x: inset, y: inset + CGFloat(start.row) * cellHeight,
                          width: CGFloat(screen.columns) * cellWidth, height: CGFloat(end.row - start.row + 1) * cellHeight)
        }
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// The character at a point on the screen.
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let window else { return NSRange(location: NSNotFound, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let row = min(max(0, Int((local.y - inset) / cellHeight)), screen.rows - 1)
        let column = max(0, Int((local.x - inset) / cellWidth))
        let text = accessibilityText
        let offset = text.offset(row: row, column: column)
        let string = text.string as NSString
        return offset < string.length ? string.rangeOfComposedCharacterSequence(at: offset) : NSRange(location: offset, length: 0)
    }
}
