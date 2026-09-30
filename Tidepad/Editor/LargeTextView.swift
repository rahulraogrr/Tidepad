import AppKit
import SwiftUI

/// The large-file view: shows a LargeTextFile of any size, drawing only the lines on screen with
/// Core Text. A whole screen anywhere in a 500 MB file takes about 1.5 ms (see "Large-file spike" in
/// CLAUDE.md), because nothing is laid out beyond what's visible: the view's height is simply the
/// line count times the line height.
///
/// It edits a LargeTextBuffer (a piece table over the mapped file): typing and input methods through
/// NSTextInputClient, delete, cut, copy and paste, undo and redo with its own NSUndoManager, and the
/// caret, selection, Go to Line and Find. Positions are byte offsets.
///
/// Input methods count in UTF-16 from the start of an "input frame": the caret's line, or for a very
/// long line the 8 KB around the caret (held still while text is being composed), so they never need
/// UTF-16 offsets for the whole file.
///
/// Lines longer than `longLineLimit` bytes (minified JSON can be one 500 MB line) aren't laid out
/// whole: the view assumes the monospaced font's advance per character to find the visible part,
/// using a map of every 4,096th character's byte offset, and lays out just that slice.
@MainActor final class LargeTextView: NSView, NSMenuItemValidation, @preconcurrency NSTextInputClient {
    let document: EditorDocument
    private(set) var buffer: LargeTextBuffer
    let scrollView = NSScrollView()
    private let ruler: LargeLineNumberRuler
    private let caretIndicator = NSTextInsertionIndicator()
    /// Where Copy puts text (a private pasteboard in checks).
    var pasteboard = NSPasteboard.general

    static let longLineLimit = 16_384
    /// Space above the first line, and left of the text: the same as the normal editor's.
    private let inset = TidepadMetrics.editorVerticalInset
    private let textInset = TidepadMetrics.editorHorizontalInset + TidepadMetrics.editorLineFragmentPadding
    private var font: NSFont
    private var paragraph: NSParagraphStyle
    private(set) var lineHeight: CGFloat = 15
    private var ascent: CGFloat = 12
    private var advance: CGFloat = 7

    /// The fixed end of the selection and the moving end (the caret), as byte offsets.
    private var anchor: Int
    private var head: Int
    /// The x position vertical moves try to keep.
    private var goalX: CGFloat?

    private struct CachedLine { let range: Range<Int>; let line: CTLine }
    private var lineCache: [Int: CachedLine] = [:]
    private var longLineMaps: [Int: LongLineMap] = [:]
    /// The buffer revision the caches were made for.
    private var cacheRevision = -1

    /// This tab's undo history (the Edit menu and ⌘Z reach it through the window's first responder).
    private let history = UndoManager()
    override var undoManager: UndoManager? { history }
    /// Consecutive typing, undone in one step, as in NSTextView.
    private final class TypingRun {
        let start: Int
        var length: Int
        let removed: [LargeTextBuffer.Piece]
        let selectionBefore: Range<Int>
        let stateBefore: UInt64
        var revision: Int
        init(start: Int, length: Int, removed: [LargeTextBuffer.Piece], selectionBefore: Range<Int>, stateBefore: UInt64, revision: Int) {
            self.start = start; self.length = length; self.removed = removed
            self.selectionBefore = selectionBefore; self.stateBefore = stateBefore; self.revision = revision
        }
    }
    private var typingRun: TypingRun?
    /// Text being composed with an input method, shown in place and underlined.
    private var marked: Range<Int>?
    private final class Composition {
        let start: Int
        var length = 0
        let removed: [LargeTextBuffer.Piece]
        let selectionBefore: Range<Int>
        let stateBefore: UInt64
        let frameStart: Int
        init(start: Int, removed: [LargeTextBuffer.Piece], selectionBefore: Range<Int>, stateBefore: UInt64, frameStart: Int) {
            self.start = start; self.removed = removed; self.selectionBefore = selectionBefore
            self.stateBefore = stateBefore; self.frameStart = frameStart
        }
    }
    private var composition: Composition?

    /// Syntax colours (LargeSyntaxEngine), and the background pass that works out the lexer's state
    /// down the file.
    private var syntax: LargeSyntaxEngine
    private var boldFont: NSFont
    private var syntaxTask: Task<Void, Never>?
    private var syntaxGeneration = 0
    /// Lines laid out with colours from a guessed lexer state, laid out again when the exact state arrives.
    private var guessedLines = Set<Int>()

    init(document: EditorDocument, buffer: LargeTextBuffer, options: EditorDisplayOptions) {
        self.document = document
        self.buffer = buffer
        font = EditorFontProvider.font(configuration: options.font)
        paragraph = EditorFontProvider.paragraphStyle(font: font, configuration: options.font)
        boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        syntax = LargeSyntaxEngine(language: document.syntaxLanguage)
        anchor = buffer.contentStart
        head = buffer.contentStart
        ruler = LargeLineNumberRuler(scrollView: scrollView)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Since macOS 14 views may draw outside their bounds; keep the text inside its scroll view.
        clipsToBounds = true
        measureFont()
        caretIndicator.displayMode = .automatic
        addSubview(caretIndicator)
        scrollView.documentView = self
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = TidepadTheme.editorBackground
        scrollView.verticalRulerView = ruler
        ruler.textView = self
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = options.showLineNumbers
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsFrameChangedNotifications = true
        setAccessibilityRole(.textArea)
        setAccessibilityLabel(document.displayName)
        updateSize()
        updateStatus()
        restartSyntaxPass()
    }

    required init?(coder: NSCoder) { fatalError("Not archivable") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    /// The same file, reopened after it changed on disk: keeps the caret's line if it still exists.
    /// Its undo history no longer applies.
    func replaceBuffer(_ newBuffer: LargeTextBuffer) {
        history.removeAllActions()
        typingRun = nil
        marked = nil
        composition = nil
        let line = buffer.line(containing: head)
        buffer = newBuffer
        lineCache.removeAll()
        longLineMaps.removeAll()
        let offset = newBuffer.lineStart(min(line, newBuffer.lineCount - 1))
        anchor = offset
        head = offset
        syntax.invalidateAll()
        restartSyntaxPass()
        updateSize()
        updateStatus()
        needsDisplay = true
        ruler.needsDisplay = true
    }

    /// Language menu: colours for another language.
    func setLanguage(_ language: SyntaxLanguage) {
        guard language != syntax.language else { return }
        syntax.setLanguage(language)
        lineCache.removeAll()
        guessedLines.removeAll()
        restartSyntaxPass()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lineCache.removeAll() // Colours differ in dark mode.
        needsDisplay = true
    }

    func applyDisplayOptions(_ options: EditorDisplayOptions) {
        let newFont = EditorFontProvider.font(configuration: options.font)
        if newFont != font || paragraph != EditorFontProvider.paragraphStyle(font: newFont, configuration: options.font) {
            let topLine = firstVisibleLine
            font = newFont
            paragraph = EditorFontProvider.paragraphStyle(font: newFont, configuration: options.font)
            measureFont()
            lineCache.removeAll()
            updateSize()
            scroll(NSPoint(x: visibleRect.minX, y: y(ofLine: topLine)))
            needsDisplay = true
            ruler.needsDisplay = true
        }
        scrollView.rulersVisible = options.showLineNumbers
    }

    // MARK: Geometry

    private func measureFont() {
        ascent = ceil(font.ascender)
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        ruler.font = font
    }

    private func updateSize() {
        let visible = scrollView.contentSize
        let width = max(visible.width, CGFloat(min(buffer.longestLine, 200_000_000)) * advance + 2 * textInset + advance)
        let height = max(visible.height, CGFloat(buffer.lineCount) * lineHeight + 2 * inset)
        setFrameSize(NSSize(width: width, height: height))
        ruler.updateThickness(lineCount: buffer.lineCount)
        updateCaret()
    }

    @objc private func boundsChanged() { updateSize() }

    func y(ofLine line: Int) -> CGFloat { inset + CGFloat(line) * lineHeight }

    private func line(atY y: CGFloat) -> Int { min(max(0, Int(floor((y - inset) / lineHeight))), buffer.lineCount - 1) }

    var firstVisibleLine: Int { line(atY: visibleRect.minY) }

    /// The lines on screen, as bytes with their line breaks.
    var visibleBytes: Range<Int> {
        let first = firstVisibleLine, last = line(atY: visibleRect.maxY)
        let end = last + 1 < buffer.lineCount ? buffer.lineStart(last + 1) : buffer.count
        return buffer.lineStart(first)..<end
    }

    /// Text from elsewhere with its line breaks changed to the file's.
    func lineBreakText(_ text: String) -> String {
        let unix = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch buffer.lineBreak {
        case .lf: return unix
        case .crlf: return unix.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return unix.replacingOccurrences(of: "\n", with: "\r")
        }
    }

    // MARK: Right-click menu

    /// Items put at the top of the right-click menu (On-Device AI).
    var contextMenuItems: (() -> [NSMenuItem])?

    /// The right-click menu: Tidepad's items, then Cut, Copy and Paste, as in a text view.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let items = contextMenuItems?() ?? []
        items.forEach(menu.addItem)
        if !items.isEmpty { menu.addItem(.separator()) }
        for (title, action) in [("Cut", #selector(cut(_:))), ("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    /// Whether a line is long enough to be laid out in slices.
    private func isLong(_ range: Range<Int>) -> Bool { range.count > Self.longLineLimit }

    /// Drops laid-out lines and long-line maps made for an older revision of the buffer.
    private func syncCaches() {
        guard cacheRevision != buffer.revision else { return }
        lineCache.removeAll(keepingCapacity: true)
        longLineMaps.removeAll()
        cacheRevision = buffer.revision
    }

    private func map(forLine line: Int, range: Range<Int>) -> LongLineMap {
        syncCaches()
        if let map = longLineMaps[line], map.range == range { return map }
        let map = LongLineMap(buffer: buffer, range: range)
        if longLineMaps.count > 8 { longLineMaps.removeAll() }
        longLineMaps[line] = map
        return map
    }

    /// The laid-out line, cached; nil for long lines, which are laid out in slices when drawn.
    private func cachedLine(_ line: Int, range: Range<Int>) -> CTLine? {
        guard !isLong(range) else { return nil }
        syncCaches()
        if let cached = lineCache[line], cached.range == range { return cached.line }
        if lineCache.count > 600 { lineCache.removeAll(keepingCapacity: true) }
        let string = buffer.text(in: range)
        let text = NSMutableAttributedString(string: string, attributes: attributes)
        if syntax.isEnabled { colour(text, line: line, string: string) }
        let ctLine = CTLineCreateWithAttributedString(text)
        lineCache[line] = CachedLine(range: range, line: ctLine)
        return ctLine
    }

    // MARK: Syntax colours

    /// Colours a line's text with the lexer's tokens, in Notepad++'s style (SyntaxPalette): the same
    /// colours as the normal editor, and the real bold face of the font for keywords and operators.
    private func colour(_ text: NSMutableAttributedString, line: Int, string: String) {
        var units = Array(string.utf16)
        units.append(10)
        let tokens = syntax.tokens(line: line, units: units, lines: buffer.forEachLine)
        if !syntax.isExact(line) {
            if guessedLines.count > 4_096 { guessedLines.removeAll() }
            guessedLines.insert(line)
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let whole = NSRange(location: 0, length: text.length)
        for token in tokens {
            let range = NSIntersectionRange(token.range, whole)
            guard range.length > 0 else { continue }
            text.addAttribute(.foregroundColor, value: SyntaxPalette.color(for: token.kind, language: syntax.language, dark: dark), range: range)
            if SyntaxPalette.isBold(token.kind) { text.addAttribute(.font, value: boldFont, range: range) }
        }
    }

    /// Starts (or restarts, after an edit) the background pass that works out the lexer's state at
    /// every 256th line, on a snapshot of the buffer, 65,536 lines at a time, lexing the file's bytes
    /// where they lie. `delay` lets typing finish first.
    private func restartSyntaxPass(after delay: Duration = .zero) {
        syntaxTask?.cancel()
        syntaxGeneration += 1
        guard syntax.isEnabled, syntax.language.carriesStateAcrossLines else { return }
        let generation = syntaxGeneration
        syntaxTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            while !Task.isCancelled {
                guard let view = self, view.syntaxGeneration == generation else { return }
                let index = view.syntax.checkpoints.count - 1
                guard index * LargeSyntaxEngine.stride < view.buffer.lineCount else { return }
                let snapshot = view.buffer.snapshot(), revision = view.buffer.revision
                let language = view.syntax.language, state = view.syntax.checkpoints[index]
                let batch = 256
                let states = await Task.detached(priority: .utility) {
                    LargeSyntaxEngine.advance(language: language, from: index, state: state, count: batch,
                                              lineCount: snapshot.lineCount, lines: snapshot.forEachLine)
                }.value
                guard let view = self, view.syntaxGeneration == generation, view.buffer.revision == revision,
                      view.syntax.append(states, after: index) else { return }
                view.syntaxAdvanced()
                if states.count < batch { return }
            }
        }
    }

    /// Lines coloured from a guessed state that now have the exact one are laid out again.
    private func syntaxAdvanced() {
        let fixed = guessedLines.filter { syntax.isExact($0) }
        guard !fixed.isEmpty else { return }
        guessedLines.subtract(fixed)
        for line in fixed { lineCache[line] = nil }
        needsDisplay = true
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: TidepadTheme.editorText, .paragraphStyle: paragraph]
    }

    /// The x of a byte offset on its line.
    private func x(of offset: Int, line: Int, range: Range<Int>) -> CGFloat {
        let offset = min(max(offset, range.lowerBound), range.upperBound)
        if isLong(range) {
            return textInset + CGFloat(map(forLine: line, range: range).characterIndex(of: offset)) * advance
        }
        guard let ctLine = cachedLine(line, range: range) else { return textInset }
        let prefix = buffer.text(in: range.lowerBound..<offset).utf16.count
        return textInset + CTLineGetOffsetForStringIndex(ctLine, prefix, nil)
    }

    /// The byte offset nearest an x position on a line.
    private func offset(atX x: CGFloat, line: Int, range: Range<Int>) -> Int {
        if isLong(range) {
            let character = max(0, Int(((x - textInset) / advance).rounded()))
            return map(forLine: line, range: range).offset(ofCharacter: character)
        }
        guard let ctLine = cachedLine(line, range: range) else { return range.lowerBound }
        let index = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: x - textInset, y: 0))
        guard index != kCFNotFound else { return range.upperBound }
        let text = buffer.text(in: range)
        let utf16 = text.utf16
        let position = utf16.index(utf16.startIndex, offsetBy: min(max(0, index), utf16.count))
        return range.lowerBound + text.utf8.distance(from: text.utf8.startIndex, to: position.samePosition(in: text.utf8) ?? text.utf8.endIndex)
    }

    private func offset(at point: NSPoint) -> Int {
        let line = line(atY: point.y)
        return offset(atX: point.x, line: line, range: buffer.lineRange(line))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dirtyRect = dirtyRect.intersection(bounds)
        TidepadTheme.editorBackground.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let first = line(atY: dirtyRect.minY), last = line(atY: dirtyRect.maxY)
        let ranges = buffer.lineRanges(from: first, count: last - first + 1)
        let caretLine = buffer.line(containing: head)
        let selection = selectedBytes
        for (index, range) in ranges.enumerated() {
            let line = first + index, top = y(ofLine: line)
            if line == caretLine && selection.isEmpty {
                TidepadTheme.currentLine.setFill()
                NSRect(x: dirtyRect.minX, y: top, width: dirtyRect.width, height: lineHeight).fill()
            }
            if !selection.isEmpty { drawSelection(selection, line: line, range: range, top: top, dirtyRect: dirtyRect) }
            if let marked, marked.lowerBound <= range.upperBound, marked.upperBound >= range.lowerBound {
                // Text being composed is underlined, as in every Mac text view.
                let startX = x(of: max(marked.lowerBound, range.lowerBound), line: line, range: range)
                let endX = x(of: min(marked.upperBound, range.upperBound), line: line, range: range)
                TidepadTheme.editorText.setFill()
                NSRect(x: startX, y: top + lineHeight - 2, width: max(1, endX - startX), height: 1).fill()
            }
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            if isLong(range) {
                drawSlice(of: line, range: range, top: top, in: context, dirtyRect: dirtyRect)
            } else if let ctLine = cachedLine(line, range: range) {
                context.textPosition = CGPoint(x: textInset, y: top + ascent)
                CTLineDraw(ctLine, context)
            }
            context.restoreGState()
        }
    }

    /// Draws the visible part of a long line: the characters under the dirty rectangle, plus a margin.
    private func drawSlice(of line: Int, range: Range<Int>, top: CGFloat, in context: CGContext, dirtyRect: NSRect) {
        let map = map(forLine: line, range: range)
        let firstCharacter = max(0, Int((dirtyRect.minX - textInset) / advance) - 16)
        let characters = Int(dirtyRect.width / advance) + 48
        let start = map.offset(ofCharacter: firstCharacter), end = map.offset(ofCharacter: firstCharacter + characters)
        guard start < end else { return }
        let text = NSAttributedString(string: buffer.text(in: start..<end), attributes: attributes)
        context.textPosition = CGPoint(x: textInset + CGFloat(firstCharacter) * advance, y: top + ascent)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }

    private func drawSelection(_ selection: Range<Int>, line: Int, range: Range<Int>, top: CGFloat, dirtyRect: NSRect) {
        // The line's bytes, including its line break.
        let lineEnd = line + 1 < buffer.lineCount ? buffer.lineStart(line + 1) : buffer.count
        guard selection.lowerBound < max(lineEnd, range.upperBound + 1), selection.upperBound > range.lowerBound else { return }
        let startX = selection.lowerBound <= range.lowerBound ? textInset : x(of: selection.lowerBound, line: line, range: range)
        // When the line break is selected too, the highlight runs to the edge, as in NSTextView.
        let endX = selection.upperBound > range.upperBound ? max(dirtyRect.maxX, visibleRect.maxX) : x(of: selection.upperBound, line: line, range: range)
        guard endX > startX else { return }
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        (focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        NSRect(x: startX, y: top, width: endX - startX, height: lineHeight).fill()
    }

    private func updateCaret() {
        let line = buffer.line(containing: head)
        let range = buffer.lineRange(line)
        let rect = NSRect(x: x(of: head, line: line, range: range), y: y(ofLine: line), width: 1, height: lineHeight)
        caretIndicator.frame = rect
        caretIndicator.isHidden = !selectedBytes.isEmpty || window?.firstResponder !== self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSize()
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; DispatchQueue.main.async { self.updateCaret() }; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; caretIndicator.isHidden = true; return true }

    // MARK: Selection

    var selectedBytes: Range<Int> { min(anchor, head)..<max(anchor, head) }

    /// Selects a range and shows it, e.g. a search match or a line.
    func select(_ range: Range<Int>, center: Bool = true) {
        typingRun = nil
        anchor = range.lowerBound
        head = range.upperBound
        goalX = nil
        selectionChanged(reveal: false)
        let line = buffer.line(containing: range.lowerBound)
        let lineRange = buffer.lineRange(line)
        let x = self.x(of: range.lowerBound, line: line, range: lineRange)
        let target = NSRect(x: max(0, x - 40), y: y(ofLine: line), width: 80, height: lineHeight)
        if center {
            let visible = visibleRect
            if !visible.contains(target) {
                let origin = NSPoint(x: target.maxX < visible.width ? 0 : target.minX - visible.width / 3,
                                     y: max(0, target.midY - visible.height / 2))
                scroll(origin)
            }
        } else {
            scrollToVisible(target)
        }
    }

    /// Go to Line (1-based).
    @discardableResult func goToLine(_ number: Int) -> Bool {
        guard number >= 1 && number <= buffer.lineCount else { return false }
        let start = buffer.lineStart(number - 1)
        select(start..<start)
        return true
    }

    private func setSelection(anchor newAnchor: Int, head newHead: Int, keepGoal: Bool = false) {
        typingRun = nil
        anchor = min(max(buffer.contentStart, newAnchor), buffer.count)
        head = min(max(buffer.contentStart, newHead), buffer.count)
        if !keepGoal { goalX = nil }
        selectionChanged(reveal: true)
    }

    private func selectionChanged(reveal: Bool) {
        updateCaret()
        updateStatus()
        needsDisplay = true
        if reveal {
            let line = buffer.line(containing: head)
            let x = self.x(of: head, line: line, range: buffer.lineRange(line))
            scrollToVisible(NSRect(x: max(0, x - 20), y: y(ofLine: line), width: 40, height: lineHeight))
        }
    }

    private func updateStatus() {
        let line = buffer.line(containing: head)
        let range = buffer.lineRange(line)
        document.cursorLine = line + 1
        let clamped = min(max(head, range.lowerBound), range.upperBound)
        document.cursorColumn = (isLong(range) ? map(forLine: line, range: range).characterIndex(of: clamped)
                                                : buffer.characterCount(in: range.lowerBound..<clamped)) + 1
        let selection = selectedBytes
        document.selectionLength = selection.count > 64 * 1_048_576 ? selection.count : buffer.characterCount(in: selection)
        document.lineCount = buffer.lineCount
        document.utf16Length = buffer.count - buffer.contentStart
    }

    // MARK: Mouse

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .iBeam) }

    private var dragUnit: (Range<Int>)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let offset = offset(at: point)
        switch event.clickCount {
        case 2:
            let word = buffer.word(at: offset)
            dragUnit = word
            setSelection(anchor: word.lowerBound, head: word.upperBound)
        case 3...:
            let line = line(atY: point.y)
            let start = buffer.lineStart(line), end = line + 1 < buffer.lineCount ? buffer.lineStart(line + 1) : buffer.count
            dragUnit = start..<end
            setSelection(anchor: start, head: end)
        default:
            dragUnit = nil
            if event.modifierFlags.contains(.shift) { setSelection(anchor: anchor, head: offset) }
            else { setSelection(anchor: offset, head: offset) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        let offset = offset(at: convert(event.locationInWindow, from: nil))
        if let unit = dragUnit {
            // Extend by words or lines from the unit first clicked.
            setSelection(anchor: offset < unit.lowerBound ? unit.upperBound : unit.lowerBound,
                         head: offset < unit.lowerBound ? offset : max(offset, unit.upperBound))
        } else {
            setSelection(anchor: anchor, head: offset)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }


    private func move(to offset: Int, extend: Bool, keepGoal: Bool = false) {
        setSelection(anchor: extend ? anchor : offset, head: offset, keepGoal: keepGoal)
    }

    private func horizontal(_ forward: Bool, extend: Bool) {
        let selection = selectedBytes
        if !extend && !selection.isEmpty { move(to: forward ? selection.upperBound : selection.lowerBound, extend: false); return }
        move(to: forward ? buffer.characterEnd(after: head) : buffer.characterStart(before: head), extend: extend)
    }

    private func vertical(_ lines: Int, extend: Bool) {
        let line = buffer.line(containing: head)
        let range = buffer.lineRange(line)
        let goal = goalX ?? x(of: head, line: line, range: range)
        let target = line + lines
        if target < 0 { move(to: buffer.contentStart, extend: extend); return }
        if target >= buffer.lineCount { move(to: buffer.count, extend: extend); return }
        let targetRange = buffer.lineRange(target)
        move(to: offset(atX: goal, line: target, range: targetRange), extend: extend, keepGoal: true)
        goalX = goal
    }

    private var pageLines: Int { max(1, Int(visibleRect.height / lineHeight) - 1) }

    private func lineEdge(_ end: Bool, extend: Bool) {
        let range = buffer.lineRange(buffer.line(containing: head))
        move(to: end ? range.upperBound : range.lowerBound, extend: extend)
    }

    private func word(_ forward: Bool, extend: Bool) {
        var offset = head
        if forward {
            while offset < buffer.count && !buffer.isWordByte(at: offset) { offset = buffer.characterEnd(after: offset) }
            while offset < buffer.count && buffer.isWordByte(at: offset) { offset += 1 }
        } else {
            while offset > buffer.contentStart && !buffer.isWordByte(at: offset - 1) { offset = buffer.characterStart(before: offset) }
            while offset > buffer.contentStart && buffer.isWordByte(at: offset - 1) { offset -= 1 }
        }
        move(to: offset, extend: extend)
    }

    override func moveLeft(_ sender: Any?) { horizontal(false, extend: false) }
    override func moveRight(_ sender: Any?) { horizontal(true, extend: false) }
    override func moveLeftAndModifySelection(_ sender: Any?) { horizontal(false, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { horizontal(true, extend: true) }
    override func moveBackward(_ sender: Any?) { horizontal(false, extend: false) }
    override func moveForward(_ sender: Any?) { horizontal(true, extend: false) }
    override func moveUp(_ sender: Any?) { vertical(-1, extend: false) }
    override func moveDown(_ sender: Any?) { vertical(1, extend: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { vertical(-1, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { vertical(1, extend: true) }
    override func moveWordLeft(_ sender: Any?) { word(false, extend: false) }
    override func moveWordRight(_ sender: Any?) { word(true, extend: false) }
    override func moveWordLeftAndModifySelection(_ sender: Any?) { word(false, extend: true) }
    override func moveWordRightAndModifySelection(_ sender: Any?) { word(true, extend: true) }
    override func moveToBeginningOfLine(_ sender: Any?) { lineEdge(false, extend: false) }
    override func moveToEndOfLine(_ sender: Any?) { lineEdge(true, extend: false) }
    override func moveToLeftEndOfLine(_ sender: Any?) { lineEdge(false, extend: false) }
    override func moveToRightEndOfLine(_ sender: Any?) { lineEdge(true, extend: false) }
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { lineEdge(false, extend: true) }
    override func moveToEndOfLineAndModifySelection(_ sender: Any?) { lineEdge(true, extend: true) }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { lineEdge(false, extend: true) }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { lineEdge(true, extend: true) }
    override func moveToBeginningOfDocument(_ sender: Any?) { move(to: buffer.contentStart, extend: false) }
    override func moveToEndOfDocument(_ sender: Any?) { move(to: buffer.count, extend: false) }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(to: buffer.contentStart, extend: true) }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(to: buffer.count, extend: true) }
    override func pageUp(_ sender: Any?) { vertical(-pageLines, extend: false) }
    override func pageDown(_ sender: Any?) { vertical(pageLines, extend: false) }
    override func pageUpAndModifySelection(_ sender: Any?) { vertical(-pageLines, extend: true) }
    override func pageDownAndModifySelection(_ sender: Any?) { vertical(pageLines, extend: true) }
    override func scrollPageUp(_ sender: Any?) { scroll(NSPoint(x: visibleRect.minX, y: max(0, visibleRect.minY - visibleRect.height))) }
    override func scrollPageDown(_ sender: Any?) { scroll(NSPoint(x: visibleRect.minX, y: visibleRect.minY + visibleRect.height)) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { scroll(.zero) }
    override func scrollToEndOfDocument(_ sender: Any?) { scroll(NSPoint(x: 0, y: bounds.height - visibleRect.height)) }
    override func cancelOperation(_ sender: Any?) { move(to: head, extend: false) }

    // MARK: Editing

    /// The bytes Return types: the file's line break.
    private var lineBreakBytes: [UInt8] {
        switch buffer.lineBreak {
        case .lf: return [0x0A]
        case .crlf: return [0x0D, 0x0A]
        case .cr: return [0x0D]
        }
    }

    private func clamp(_ range: Range<Int>) -> Range<Int> {
        let lower = min(max(buffer.contentStart, range.lowerBound), buffer.count)
        return lower..<min(buffer.count, max(lower, range.upperBound))
    }

    private static func characters(in pieces: [LargeTextBuffer.Piece]) -> Int {
        pieces.reduce(0) { total, piece in
            var count = 0
            for k in 0..<piece.length where piece.source.base[piece.start + k] & 0xC0 != 0x80 { count += 1 }
            return total + count
        }
    }

    /// Before the buffer changes: keeps the edited long line's map (moved to fit), drops the others.
    private func noteEdit(replacing range: Range<Int>, with pieces: [LargeTextBuffer.Piece]) {
        syncCaches()
        let line = buffer.line(containing: range.lowerBound)
        if syntax.isEnabled {
            syntax.invalidate(fromLine: line)
            if syntax.language.carriesStateAcrossLines { restartSyntaxPass(after: .seconds(1)) }
        }
        // (Not for big edits such as Replace All over a long line: counting their characters costs more
        // than building the map again.)
        if var map = longLineMaps[line], range.count <= 1 << 20, pieces.count <= 1_024, pieces.allSatisfy({ $0.breaks == 0 }),
           range.lowerBound >= map.range.lowerBound, range.upperBound <= map.range.upperBound {
            map.edited(at: range.lowerBound, removedBytes: range.count, removedCharacters: buffer.characterCount(in: range),
                       insertedBytes: pieces.reduce(0) { $0 + $1.length }, insertedCharacters: Self.characters(in: pieces))
            longLineMaps = [line: map]
        } else {
            longLineMaps.removeAll()
        }
        lineCache.removeAll(keepingCapacity: true)
    }

    /// After the buffer changed: caches, size, caret, status bar.
    private func textChanged(select selection: Range<Int>) {
        cacheRevision = buffer.revision
        anchor = selection.lowerBound
        head = selection.upperBound
        goalX = nil
        updateSize()
        selectionChanged(reveal: true)
        ruler.needsDisplay = true
    }

    /// Replaces a range with pieces as one undoable step; undo puts back what was there, and the
    /// document's saved state with it (undoing to the saved text clears the unsaved dot).
    private func replace(_ range: Range<Int>, with pieces: [LargeTextBuffer.Piece], select selection: Range<Int>? = nil,
                         action: String, state: UInt64? = nil) {
        typingRun = nil
        let range = clamp(range)
        let previousSelection = selectedBytes, previousState = document.editingState
        noteEdit(replacing: range, with: pieces)
        let removed = buffer.replace(range, with: pieces)
        let inserted = range.lowerBound..<(range.lowerBound + pieces.reduce(0) { $0 + $1.length })
        document.recordEdit()
        document.setEditingState(state ?? document.revision)
        history.registerUndo(withTarget: self) { view in
            view.replace(inserted, with: removed, select: previousSelection, action: action, state: previousState)
        }
        history.setActionName(action)
        textChanged(select: selection ?? (inserted.upperBound..<inserted.upperBound))
    }

    /// Replace and Replace All: the edits (in order, inside `range`) as one undoable step. The
    /// unchanged text between them stays pieces of the file, so nothing is copied.
    func replace(matches edits: [(range: Range<Int>, bytes: [UInt8])], in range: Range<Int>, select selection: Range<Int>, action: String) {
        guard !edits.isEmpty else { return }
        replace(range, with: buffer.pieces(in: clamp(range), replacing: edits), select: selection, action: action)
    }

    /// Typing: consecutive characters extend one undo step.
    private func type(_ bytes: [UInt8], replacing target: Range<Int>) {
        let target = clamp(target)
        let pieces = buffer.pieces(for: bytes)
        if let run = typingRun, target.isEmpty, target.lowerBound == run.start + run.length, run.revision == buffer.revision {
            noteEdit(replacing: target, with: pieces)
            buffer.replace(target, with: pieces)
            run.length += bytes.count
            run.revision = buffer.revision
            document.recordEdit()
            textChanged(select: (target.lowerBound + bytes.count)..<(target.lowerBound + bytes.count))
            return
        }
        let selectionBefore = selectedBytes, stateBefore = document.editingState
        noteEdit(replacing: target, with: pieces)
        let removed = buffer.replace(target, with: pieces)
        document.recordEdit()
        document.setEditingState(document.revision)
        let run = TypingRun(start: target.lowerBound, length: bytes.count, removed: removed, selectionBefore: selectionBefore,
                            stateBefore: stateBefore, revision: buffer.revision)
        history.registerUndo(withTarget: self) { view in
            view.replace(run.start..<(run.start + run.length), with: run.removed, select: run.selectionBefore, action: "Typing", state: run.stateBefore)
        }
        history.setActionName("Typing")
        textChanged(select: (target.lowerBound + bytes.count)..<(target.lowerBound + bytes.count))
        typingRun = run
    }

    private func deleteBytes(_ range: Range<Int>) {
        guard !range.isEmpty else { NSSound.beep(); return }
        replace(range, with: [], action: "Delete")
    }

    override func insertNewline(_ sender: Any?) { type(lineBreakBytes, replacing: selectedBytes) }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }
    override func insertLineBreak(_ sender: Any?) { insertNewline(sender) }
    override func insertTab(_ sender: Any?) { type([0x09], replacing: selectedBytes) }
    override func insertTabIgnoringFieldEditor(_ sender: Any?) { insertTab(sender) }
    override func deleteBackward(_ sender: Any?) {
        deleteBytes(selectedBytes.isEmpty ? buffer.characterStart(before: head)..<head : selectedBytes)
    }
    override func deleteForward(_ sender: Any?) {
        deleteBytes(selectedBytes.isEmpty ? head..<buffer.characterEnd(after: head) : selectedBytes)
    }
    override func deleteWordBackward(_ sender: Any?) {
        guard selectedBytes.isEmpty else { deleteBytes(selectedBytes); return }
        var start = head
        while start > buffer.contentStart && !buffer.isWordByte(at: start - 1) { start = buffer.characterStart(before: start) }
        while start > buffer.contentStart && buffer.isWordByte(at: start - 1) { start -= 1 }
        deleteBytes(start..<head)
    }
    override func deleteWordForward(_ sender: Any?) {
        guard selectedBytes.isEmpty else { deleteBytes(selectedBytes); return }
        var end = head
        while end < buffer.count && !buffer.isWordByte(at: end) { end = buffer.characterEnd(after: end) }
        while end < buffer.count && buffer.isWordByte(at: end) { end += 1 }
        deleteBytes(head..<end)
    }
    override func deleteToBeginningOfLine(_ sender: Any?) {
        guard selectedBytes.isEmpty else { deleteBytes(selectedBytes); return }
        let start = buffer.lineRange(buffer.line(containing: head)).lowerBound
        deleteBytes((head == start ? buffer.characterStart(before: head) : start)..<head)
    }
    override func deleteToEndOfLine(_ sender: Any?) {
        guard selectedBytes.isEmpty else { deleteBytes(selectedBytes); return }
        let end = buffer.lineRange(buffer.line(containing: head)).upperBound
        deleteBytes(head..<(head == end ? buffer.characterEnd(after: head) : end))
    }

    // MARK: NSTextInputClient

    /// The bytes input methods see, counted in UTF-16 from its start (see the class comment).
    private func inputFrame() -> Range<Int> {
        let range = buffer.lineRange(buffer.line(containing: head))
        guard range.count > Self.longLineLimit else { return range }
        var lower = composition?.frameStart ?? max(range.lowerBound, head - 4_096)
        while lower > range.lowerBound && buffer.byte(at: lower) & 0xC0 == 0x80 { lower -= 1 }
        var upper = min(range.upperBound, max(head, lower) + 8_192)
        while upper < range.upperBound && buffer.byte(at: upper) & 0xC0 == 0x80 { upper += 1 }
        return lower..<upper
    }

    /// A byte range as UTF-16 in the input frame (clamped to the frame).
    private func utf16Range(_ bytes: Range<Int>, in frame: Range<Int>) -> NSRange {
        let lower = min(max(bytes.lowerBound, frame.lowerBound), frame.upperBound)
        let upper = min(max(bytes.upperBound, lower), frame.upperBound)
        let location = buffer.text(in: frame.lowerBound..<lower).utf16.count
        return NSRange(location: location, length: buffer.text(in: lower..<upper).utf16.count)
    }

    /// A UTF-16 range in the input frame as bytes.
    private func byteRange(_ range: NSRange, in frame: Range<Int>) -> Range<Int>? {
        guard range.location != NSNotFound else { return nil }
        let text = buffer.text(in: frame)
        func offset(_ utf16Offset: Int) -> Int {
            let utf16 = text.utf16
            let index = utf16.index(utf16.startIndex, offsetBy: min(max(0, utf16Offset), utf16.count))
            let position = index.samePosition(in: text.utf8) ?? text.utf8.endIndex
            return frame.lowerBound + text.utf8.distance(from: text.utf8.startIndex, to: position)
        }
        let lower = offset(range.location)
        return lower..<max(lower, offset(range.location + range.length))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let bytes = Array(text.utf8)
        if let marked, let composition {
            // The composed text is committed: one undo step from before the composition started.
            let pieces = buffer.pieces(for: bytes)
            noteEdit(replacing: marked, with: pieces)
            buffer.replace(marked, with: pieces)
            self.marked = nil
            composition.length = bytes.count
            document.recordEdit()
            textChanged(select: (marked.lowerBound + bytes.count)..<(marked.lowerBound + bytes.count))
            finishComposition()
            return
        }
        let target = byteRange(replacementRange, in: inputFrame()) ?? selectedBytes
        type(bytes, replacing: target)
    }

    func setMarkedText(_ string: Any, selectedRange selection: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        typingRun = nil
        let target = clamp(marked ?? byteRange(replacementRange, in: inputFrame()) ?? selectedBytes)
        if composition == nil {
            composition = Composition(start: target.lowerBound, removed: buffer.pieces(in: target), selectionBefore: selectedBytes,
                                      stateBefore: document.editingState, frameStart: inputFrame().lowerBound)
        }
        let bytes = Array(text.utf8)
        let pieces = buffer.pieces(for: bytes)
        noteEdit(replacing: target, with: pieces)
        buffer.replace(target, with: pieces)
        composition?.length = bytes.count
        document.recordEdit()
        document.setEditingState(document.revision)
        marked = bytes.isEmpty ? nil : target.lowerBound..<(target.lowerBound + bytes.count)
        // The caret inside the composed text, from the input method's UTF-16 selection.
        let prefix = String(decoding: Array(text.utf16.prefix(max(0, min(selection.location, text.utf16.count)))), as: UTF16.self)
        let caret = target.lowerBound + prefix.utf8.count
        textChanged(select: caret..<caret)
        if marked == nil { finishComposition() }
    }

    func unmarkText() {
        guard marked != nil else { return }
        marked = nil
        finishComposition()
        needsDisplay = true
    }

    /// Registers the whole composition as one undo step.
    private func finishComposition() {
        guard let composition else { return }
        self.composition = nil
        history.registerUndo(withTarget: self) { view in
            view.replace(composition.start..<(composition.start + composition.length), with: composition.removed,
                         select: composition.selectionBefore, action: "Typing", state: composition.stateBefore)
        }
        history.setActionName("Typing")
    }

    func selectedRange() -> NSRange { utf16Range(selectedBytes, in: inputFrame()) }

    func markedRange() -> NSRange {
        guard let marked else { return NSRange(location: NSNotFound, length: 0) }
        return utf16Range(marked, in: inputFrame())
    }

    func hasMarkedText() -> Bool { marked != nil }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let frame = inputFrame()
        guard let bytes = byteRange(range, in: frame) else { return nil }
        actualRange?.pointee = utf16Range(bytes, in: frame)
        return NSAttributedString(string: buffer.text(in: bytes), attributes: attributes)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }

    /// Where input method windows (candidates, accents) appear: on screen, below the text.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let frame = inputFrame()
        let bytes = byteRange(range, in: frame) ?? selectedBytes
        let line = buffer.line(containing: bytes.lowerBound), lineRange = buffer.lineRange(line)
        let startX = x(of: bytes.lowerBound, line: line, range: lineRange)
        let endX = x(of: min(bytes.upperBound, lineRange.upperBound), line: line, range: lineRange)
        actualRange?.pointee = utf16Range(bytes, in: frame)
        let rect = NSRect(x: startX, y: y(ofLine: line), width: max(1, endX - startX), height: lineHeight)
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return NSNotFound }
        let offset = offset(at: convert(window.convertPoint(fromScreen: point), from: nil))
        let frame = inputFrame()
        guard frame.contains(offset) || offset == frame.upperBound else { return NSNotFound }
        return utf16Range(offset..<offset, in: frame).location
    }

    // MARK: Edit menu

    override func selectAll(_ sender: Any?) { setSelection(anchor: buffer.contentStart, head: buffer.count); needsDisplay = true }

    @objc func copy(_ sender: Any?) {
        let selection = selectedBytes
        guard !selection.isEmpty else { NSSound.beep(); return }
        pasteboard.clearContents()
        pasteboard.setString(buffer.text(in: selection), forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        guard !selectedBytes.isEmpty else { NSSound.beep(); return }
        copy(sender)
        replace(selectedBytes, with: [], action: "Cut")
    }

    @objc func paste(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { NSSound.beep(); return }
        replace(selectedBytes, with: buffer.pieces(for: Array(text.utf8)), action: "Paste")
    }

    @objc func delete(_ sender: Any?) { deleteBytes(selectedBytes) }

    /// Edit ▸ Undo and Redo. The window's own undo: would use the window's undo manager, not this
    /// tab's, so the view answers them itself (it's first in the responder chain).
    @objc func undo(_ sender: Any?) { if history.canUndo { history.undo() } else { NSSound.beep() } }
    @objc func redo(_ sender: Any?) { if history.canRedo { history.redo() } else { NSSound.beep() } }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): return !selectedBytes.isEmpty
        case #selector(paste(_:)): return pasteboard.string(forType: .string) != nil
        case #selector(undo(_:)):
            menuItem.title = history.undoMenuItemTitle
            return history.canUndo
        case #selector(redo(_:)):
            menuItem.title = history.redoMenuItemTitle
            return history.canRedo
        default: return true
        }
    }
}

/// For one long line: checkpoints pairing a character index with its byte offset (every 4,096th
/// character when made; edits move the ones after them), so a character position (and so an x
/// position, at the monospaced font's advance) finds its bytes without decoding from the line start.
struct LongLineMap {
    static let stride = 4_096
    private(set) var range: Range<Int>
    private var characters: [Int]
    private var offsets: [Int]
    private let buffer: LargeTextBuffer

    init(buffer: LargeTextBuffer, range: Range<Int>) {
        self.buffer = buffer
        self.range = range
        var characters = [0], offsets = [range.lowerBound]
        var count = 0
        buffer.forEachSegment(in: range) { start, bytes, length in
            for k in 0..<length where bytes[k] & 0xC0 != 0x80 {
                if count > 0 && count % Self.stride == 0 { characters.append(count); offsets.append(start + k) }
                count += 1
            }
            return true
        }
        self.characters = characters
        self.offsets = offsets
    }

    /// After an edit inside the line that added or removed no line break: checkpoints in the replaced
    /// bytes go, later ones move.
    mutating func edited(at position: Int, removedBytes: Int, removedCharacters: Int, insertedBytes: Int, insertedCharacters: Int) {
        var newCharacters: [Int] = [], newOffsets: [Int] = []
        for (character, offset) in zip(characters, offsets) {
            if offset <= position {
                newCharacters.append(character); newOffsets.append(offset)
            } else if offset > position + removedBytes {
                newCharacters.append(character - removedCharacters + insertedCharacters)
                newOffsets.append(offset - removedBytes + insertedBytes)
            }
        }
        characters = newCharacters
        offsets = newOffsets
        range = range.lowerBound..<(range.upperBound - removedBytes + insertedBytes)
    }

    private static func last(_ values: [Int], atMost value: Int) -> Int {
        var low = 0, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    /// The byte offset where a character starts (clamped to the line).
    func offset(ofCharacter character: Int) -> Int {
        let character = max(0, character)
        let k = Self.last(characters, atMost: character)
        var offset = offsets[k], remaining = character - characters[k]
        while remaining > 0 && offset < range.upperBound {
            offset = min(buffer.characterEnd(after: offset), range.upperBound)
            remaining -= 1
        }
        return offset
    }

    /// The character index of a byte offset on the line.
    func characterIndex(of offset: Int) -> Int {
        let offset = min(max(offset, range.lowerBound), range.upperBound)
        let k = Self.last(offsets, atMost: offset)
        return characters[k] + buffer.characterCount(in: offsets[k]..<offset)
    }
}

/// Line numbers for the large-file view, drawn only for the lines on screen.
@MainActor final class LargeLineNumberRuler: NSRulerView {
    weak var textView: LargeTextView?
    var font = EditorFontProvider.font()

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clipsToBounds = true // The gutter must not paint over the text beside it (views may draw outside their bounds since macOS 14).
        ruleThickness = TidepadMetrics.gutterMinimumWidth
    }
    required init(coder: NSCoder) { fatalError("Not archivable") }

    func updateThickness(lineCount: Int) {
        let digits = String(lineCount).count
        let width = max(TidepadMetrics.gutterMinimumWidth, CGFloat(digits) * ("0" as NSString).size(withAttributes: [.font: font]).width
                        + TidepadMetrics.gutterPadding + TidepadMetrics.gutterLeadingPadding)
        if ruleThickness != width { ruleThickness = width }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        TidepadTheme.gutterBackground.setFill()
        bounds.fill()
        TidepadTheme.separator.setFill()
        NSRect(x: bounds.maxX - TidepadMetrics.separatorWidth, y: bounds.minY, width: TidepadMetrics.separatorWidth, height: bounds.height).fill()
        guard let textView else { return }
        let visible = textView.visibleRect
        let first = max(0, Int((visible.minY - 4) / textView.lineHeight))
        let last = min(textView.buffer.lineCount - 1, Int((visible.maxY - 4) / textView.lineHeight) + 1)
        guard first <= last else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: TidepadTheme.gutterText]
        for line in first...last {
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: attributes)
            let y = convert(NSPoint(x: 0, y: textView.y(ofLine: line)), from: textView).y
            label.draw(at: NSPoint(x: ruleThickness - size.width - TidepadMetrics.gutterPadding, y: y), withAttributes: attributes)
        }
    }
}

/// Shows a large-file tab's view (kept by EditorSessionStore, so switching tabs keeps its place).
struct LargeFileHostView: NSViewRepresentable {
    let view: LargeTextView
    /// The document's buffer: a new one after the file changed on disk.
    let buffer: LargeTextBuffer
    let options: EditorDisplayOptions

    func makeNSView(context: Context) -> NSScrollView {
        view.applyDisplayOptions(options)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if buffer !== view.buffer { view.replaceBuffer(buffer) }
        view.applyDisplayOptions(options)
    }
}
