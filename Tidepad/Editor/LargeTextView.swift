import AppKit
import SwiftUI

/// The large-file view: shows a LargeTextFile of any size, drawing only the lines on screen with
/// Core Text. A whole screen anywhere in a 500 MB file takes about 1.5 ms (see "Large-file spike" in
/// CLAUDE.md), because nothing is laid out beyond what's visible: the view's height is simply the
/// line count times the line height.
///
/// Phase A is read-only: scrolling, the caret, selection (mouse and keyboard), Copy, Select All,
/// Go to Line and Find. Positions are byte offsets into the file.
///
/// Lines longer than `longLineLimit` bytes (minified JSON can be one 500 MB line) aren't laid out
/// whole: the view assumes the monospaced font's advance per character to find the visible part,
/// using a map of every 4,096th character's byte offset, and lays out just that slice.
@MainActor final class LargeTextView: NSView, NSMenuItemValidation {
    let document: EditorDocument
    private(set) var file: LargeTextFile
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

    init(document: EditorDocument, file: LargeTextFile, options: EditorDisplayOptions) {
        self.document = document
        self.file = file
        font = EditorFontProvider.font(configuration: options.font)
        paragraph = EditorFontProvider.paragraphStyle(font: font, configuration: options.font)
        anchor = file.contentStart
        head = file.contentStart
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
    }

    required init?(coder: NSCoder) { fatalError("Not archivable") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    /// The same file, reopened after it changed on disk: keeps the caret's line if it still exists.
    func replaceFile(_ newFile: LargeTextFile) {
        let line = file.line(containing: head)
        file = newFile
        lineCache.removeAll()
        longLineMaps.removeAll()
        let offset = newFile.lineStart(min(line, newFile.lineCount - 1))
        anchor = offset
        head = offset
        updateSize()
        updateStatus()
        needsDisplay = true
        ruler.needsDisplay = true
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
        ruler.font = font
    }

    private func updateSize() {
        let visible = scrollView.contentSize
        let width = max(visible.width, CGFloat(min(file.longestLine, 200_000_000)) * advance + 2 * textInset + advance)
        let height = max(visible.height, CGFloat(file.lineCount) * lineHeight + 2 * inset)
        setFrameSize(NSSize(width: width, height: height))
        ruler.updateThickness(lineCount: file.lineCount)
        updateCaret()
    }

    @objc private func boundsChanged() { updateSize() }

    func y(ofLine line: Int) -> CGFloat { inset + CGFloat(line) * lineHeight }

    private func line(atY y: CGFloat) -> Int { min(max(0, Int(floor((y - inset) / lineHeight))), file.lineCount - 1) }

    var firstVisibleLine: Int { line(atY: visibleRect.minY) }

    /// Whether a line is long enough to be laid out in slices.
    private func isLong(_ range: Range<Int>) -> Bool { range.count > Self.longLineLimit }

    private func map(forLine line: Int, range: Range<Int>) -> LongLineMap {
        if let map = longLineMaps[line] { return map }
        let map = LongLineMap(file: file, range: range)
        if longLineMaps.count > 8 { longLineMaps.removeAll() }
        longLineMaps[line] = map
        return map
    }

    /// The laid-out line, cached; nil for long lines, which are laid out in slices when drawn.
    private func cachedLine(_ line: Int, range: Range<Int>) -> CTLine? {
        guard !isLong(range) else { return nil }
        if let cached = lineCache[line], cached.range == range { return cached.line }
        if lineCache.count > 600 { lineCache.removeAll(keepingCapacity: true) }
        let text = NSAttributedString(string: file.text(in: range), attributes: attributes)
        let ctLine = CTLineCreateWithAttributedString(text)
        lineCache[line] = CachedLine(range: range, line: ctLine)
        return ctLine
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
        let prefix = file.text(in: range.lowerBound..<offset).utf16.count
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
        let text = file.text(in: range)
        let utf16 = text.utf16
        let position = utf16.index(utf16.startIndex, offsetBy: min(max(0, index), utf16.count))
        return range.lowerBound + text.utf8.distance(from: text.utf8.startIndex, to: position.samePosition(in: text.utf8) ?? text.utf8.endIndex)
    }

    private func offset(at point: NSPoint) -> Int {
        let line = line(atY: point.y)
        return offset(atX: point.x, line: line, range: file.lineRange(line))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dirtyRect = dirtyRect.intersection(bounds)
        TidepadTheme.editorBackground.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let first = line(atY: dirtyRect.minY), last = line(atY: dirtyRect.maxY)
        let ranges = file.lineRanges(from: first, count: last - first + 1)
        let caretLine = file.line(containing: head)
        let selection = selectedRange
        for (index, range) in ranges.enumerated() {
            let line = first + index, top = y(ofLine: line)
            if line == caretLine && selection.isEmpty {
                TidepadTheme.currentLine.setFill()
                NSRect(x: dirtyRect.minX, y: top, width: dirtyRect.width, height: lineHeight).fill()
            }
            if !selection.isEmpty { drawSelection(selection, line: line, range: range, top: top, dirtyRect: dirtyRect) }
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
        let text = NSAttributedString(string: file.text(in: start..<end), attributes: attributes)
        context.textPosition = CGPoint(x: textInset + CGFloat(firstCharacter) * advance, y: top + ascent)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }

    private func drawSelection(_ selection: Range<Int>, line: Int, range: Range<Int>, top: CGFloat, dirtyRect: NSRect) {
        // The line's bytes, including its line break.
        let lineEnd = line + 1 < file.lineCount ? file.lineStart(line + 1) : file.count
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
        let line = file.line(containing: head)
        let range = file.lineRange(line)
        let rect = NSRect(x: x(of: head, line: line, range: range), y: y(ofLine: line), width: 1, height: lineHeight)
        caretIndicator.frame = rect
        caretIndicator.isHidden = !selectedRange.isEmpty || window?.firstResponder !== self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSize()
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; DispatchQueue.main.async { self.updateCaret() }; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; caretIndicator.isHidden = true; return true }

    // MARK: Selection

    var selectedRange: Range<Int> { min(anchor, head)..<max(anchor, head) }

    /// Selects a range and shows it, e.g. a search match or a line.
    func select(_ range: Range<Int>, center: Bool = true) {
        anchor = range.lowerBound
        head = range.upperBound
        goalX = nil
        selectionChanged(reveal: false)
        let line = file.line(containing: range.lowerBound)
        let lineRange = file.lineRange(line)
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
        guard number >= 1 && number <= file.lineCount else { return false }
        let start = file.lineStart(number - 1)
        select(start..<start)
        return true
    }

    private func setSelection(anchor newAnchor: Int, head newHead: Int, keepGoal: Bool = false) {
        anchor = min(max(file.contentStart, newAnchor), file.count)
        head = min(max(file.contentStart, newHead), file.count)
        if !keepGoal { goalX = nil }
        selectionChanged(reveal: true)
    }

    private func selectionChanged(reveal: Bool) {
        updateCaret()
        updateStatus()
        needsDisplay = true
        if reveal {
            let line = file.line(containing: head)
            let x = self.x(of: head, line: line, range: file.lineRange(line))
            scrollToVisible(NSRect(x: max(0, x - 20), y: y(ofLine: line), width: 40, height: lineHeight))
        }
    }

    private func updateStatus() {
        let line = file.line(containing: head)
        let range = file.lineRange(line)
        document.cursorLine = line + 1
        let clamped = min(max(head, range.lowerBound), range.upperBound)
        document.cursorColumn = (isLong(range) ? map(forLine: line, range: range).characterIndex(of: clamped)
                                                : file.characterCount(in: range.lowerBound..<clamped)) + 1
        let selection = selectedRange
        document.selectionLength = selection.count > 64 * 1_048_576 ? selection.count : file.characterCount(in: selection)
        document.lineCount = file.lineCount
        document.utf16Length = file.count - file.contentStart
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
            let word = file.word(at: offset)
            dragUnit = word
            setSelection(anchor: word.lowerBound, head: word.upperBound)
        case 3...:
            let line = line(atY: point.y)
            let start = file.lineStart(line), end = line + 1 < file.lineCount ? file.lineStart(line + 1) : file.count
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

    /// Phase A is read-only: typing beeps.
    override func insertText(_ insertString: Any) { NSSound.beep() }

    private func move(to offset: Int, extend: Bool, keepGoal: Bool = false) {
        setSelection(anchor: extend ? anchor : offset, head: offset, keepGoal: keepGoal)
    }

    private func horizontal(_ forward: Bool, extend: Bool) {
        let selection = selectedRange
        if !extend && !selection.isEmpty { move(to: forward ? selection.upperBound : selection.lowerBound, extend: false); return }
        move(to: forward ? file.characterEnd(after: head) : file.characterStart(before: head), extend: extend)
    }

    private func vertical(_ lines: Int, extend: Bool) {
        let line = file.line(containing: head)
        let range = file.lineRange(line)
        let goal = goalX ?? x(of: head, line: line, range: range)
        let target = line + lines
        if target < 0 { move(to: file.contentStart, extend: extend); return }
        if target >= file.lineCount { move(to: file.count, extend: extend); return }
        let targetRange = file.lineRange(target)
        move(to: offset(atX: goal, line: target, range: targetRange), extend: extend, keepGoal: true)
        goalX = goal
    }

    private var pageLines: Int { max(1, Int(visibleRect.height / lineHeight) - 1) }

    private func lineEdge(_ end: Bool, extend: Bool) {
        let range = file.lineRange(file.line(containing: head))
        move(to: end ? range.upperBound : range.lowerBound, extend: extend)
    }

    private func word(_ forward: Bool, extend: Bool) {
        var offset = head
        if forward {
            while offset < file.count && !file.isWordByte(at: offset) { offset = file.characterEnd(after: offset) }
            while offset < file.count && file.isWordByte(at: offset) { offset += 1 }
        } else {
            while offset > file.contentStart && !file.isWordByte(at: offset - 1) { offset = file.characterStart(before: offset) }
            while offset > file.contentStart && file.isWordByte(at: offset - 1) { offset -= 1 }
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
    override func moveToBeginningOfDocument(_ sender: Any?) { move(to: file.contentStart, extend: false) }
    override func moveToEndOfDocument(_ sender: Any?) { move(to: file.count, extend: false) }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(to: file.contentStart, extend: true) }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(to: file.count, extend: true) }
    override func pageUp(_ sender: Any?) { vertical(-pageLines, extend: false) }
    override func pageDown(_ sender: Any?) { vertical(pageLines, extend: false) }
    override func pageUpAndModifySelection(_ sender: Any?) { vertical(-pageLines, extend: true) }
    override func pageDownAndModifySelection(_ sender: Any?) { vertical(pageLines, extend: true) }
    override func scrollPageUp(_ sender: Any?) { scroll(NSPoint(x: visibleRect.minX, y: max(0, visibleRect.minY - visibleRect.height))) }
    override func scrollPageDown(_ sender: Any?) { scroll(NSPoint(x: visibleRect.minX, y: visibleRect.minY + visibleRect.height)) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { scroll(.zero) }
    override func scrollToEndOfDocument(_ sender: Any?) { scroll(NSPoint(x: 0, y: bounds.height - visibleRect.height)) }
    override func cancelOperation(_ sender: Any?) { move(to: head, extend: false) }

    // MARK: Edit menu

    override func selectAll(_ sender: Any?) { setSelection(anchor: file.contentStart, head: file.count); needsDisplay = true }

    @objc func copy(_ sender: Any?) {
        let selection = selectedRange
        guard !selection.isEmpty else { NSSound.beep(); return }
        pasteboard.clearContents()
        pasteboard.setString(file.text(in: selection), forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return !selectedRange.isEmpty
        case #selector(selectAll(_:)): return true
        default: return false // Read-only: Cut, Paste, Delete and Undo stay disabled.
        }
    }
}

/// For one long line: the byte offset of every 4,096th character, so a character position (and so
/// an x position, at the monospaced font's advance) finds its bytes without decoding from the start.
struct LongLineMap {
    static let stride = 4_096
    let range: Range<Int>
    private let checkpoints: [Int]
    private let isASCII: Bool
    private let file: LargeTextFile

    init(file: LargeTextFile, range: Range<Int>) {
        self.file = file
        self.range = range
        var checkpoints = [range.lowerBound]
        var characters = 0, ascii = true
        var k = range.lowerBound
        while k < range.upperBound {
            let byte = file.byte(at: k)
            if byte & 0xC0 != 0x80 {
                if characters > 0 && characters % Self.stride == 0 { checkpoints.append(k) }
                characters += 1
            }
            if byte >= 0x80 { ascii = false }
            k += 1
        }
        self.checkpoints = checkpoints
        isASCII = ascii
    }

    /// The byte offset where a character starts (clamped to the line).
    func offset(ofCharacter character: Int) -> Int {
        if isASCII { return min(range.lowerBound + max(0, character), range.upperBound) }
        let block = min(max(0, character) / Self.stride, checkpoints.count - 1)
        var offset = checkpoints[block], remaining = max(0, character) - block * Self.stride
        while remaining > 0 && offset < range.upperBound {
            offset = min(file.characterEnd(after: offset), range.upperBound)
            remaining -= 1
        }
        return offset
    }

    /// The character index of a byte offset on the line.
    func characterIndex(of offset: Int) -> Int {
        let offset = min(max(offset, range.lowerBound), range.upperBound)
        if isASCII { return offset - range.lowerBound }
        var low = 0, high = checkpoints.count
        while low < high {
            let middle = (low + high) / 2
            if checkpoints[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        let block = max(0, low - 1)
        return block * Self.stride + file.characterCount(in: checkpoints[block]..<offset)
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
        let last = min(textView.file.lineCount - 1, Int((visible.maxY - 4) / textView.lineHeight) + 1)
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
    /// The document's file: a new one after the file changed on disk.
    let file: LargeTextFile
    let options: EditorDisplayOptions

    func makeNSView(context: Context) -> NSScrollView {
        view.applyDisplayOptions(options)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if file !== view.file { view.replaceFile(file) }
        view.applyDisplayOptions(options)
    }
}
