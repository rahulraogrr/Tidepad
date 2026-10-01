import AppKit

final class CodeTextView: NSTextView {
    // Edit ▸ Undo and Redo use this tab's own undo manager (EditorSession gives each tab one, through
    // undoManager(for:)); the window's undo: would use the window's, shared by every tab.
    @objc func undo(_ sender: Any?) {
        guard isEditable, let manager = undoManager, manager.canUndo else { NSSound.beep(); return }
        manager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard isEditable, let manager = undoManager, manager.canRedo else { NSSound.beep(); return }
        manager.redo()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return isEditable && undoManager?.canUndo == true
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return isEditable && undoManager?.canRedo == true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    /// What Return types: the document's line break, so a Windows (CRLF) file stays CRLF, as in Notepad++.
    var lineBreak = "\n"
    var matchingBrackets: [NSRange] = []
    var appearanceChanged: (() -> Void)?
    /// Opens files dropped on the editor, as Notepad++ does, instead of inserting their paths.
    var openFiles: (([URL]) -> Void)?
    /// The link shown at a character index, if any. ⌘-click opens it with its default app.
    var linkAt: ((Int) -> URL?)?
    /// Items put at the top of the right-click menu, above NSTextView's own (On-Device AI).
    var contextMenuItems: (() -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let items = contextMenuItems?() ?? []
        guard !items.isEmpty else { return menu }
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }

    override func insertNewline(_ sender: Any?) {
        guard lineBreak != "\n" else { super.insertNewline(sender); return }
        insertText(lineBreak, replacementRange: selectedRange())
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = link(under: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Show that ⌘-click will follow the link under the pointer.
        if event.modifierFlags.contains(.command), link(under: event) != nil { NSCursor.pointingHand.set() }
    }

    /// The link under the mouse: only when the pointer is on the link's glyphs, not past the line's end.
    private func link(under event: NSEvent) -> URL? {
        guard let linkAt, let layout = layoutManager, let container = textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: location, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(location) else { return nil }
        return linkAt(layout.characterIndexForGlyph(at: glyph))
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        guard openFiles != nil else { return [] }
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty, let openFiles else { return super.performDragOperation(sender) }
        openFiles(files)
        return true
    }

    /// Where the current-line highlight and bracket boxes were last drawn, so a caret move redraws only
    /// those and the new ones, not the whole screen (Rule 2: a keystroke shouldn't repaint everything).
    private(set) var decorationRects: [NSRect] = []

    func updateCaretDecorations() {
        let selection = selectedRange()
        matchingBrackets = selection.length == 0
            ? BracketMatcher.match(in: textStorage?.mutableString ?? NSMutableString(), caret: selection.location) : []
        let now = decorations()
        let rects = [now.line].compactMap { $0 } + now.brackets
        for rect in decorationRects + rects { setNeedsDisplay(rect.insetBy(dx: -1, dy: -1)) }
        decorationRects = rects
    }

    /// The caret's line (across the whole view) and the matching brackets' boxes, in view coordinates.
    /// Nothing while the caret is off screen: finding its line would lay out the file up to it.
    private func decorations() -> (line: NSRect?, brackets: [NSRect]) {
        guard let layout = layoutManager, let container = textContainer else { return (nil, []) }
        let length = (textStorage?.length ?? 0)
        let caret = min(selectedRange().location, length)
        let visible = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard caret >= characters.location, caret <= NSMaxRange(characters) else { return (nil, []) }
        let fragment: NSRect
        if caret == length && (length == 0 || layout.extraLineFragmentTextContainer != nil) {
            fragment = layout.extraLineFragmentRect
        } else if length > 0 {
            let glyph = layout.glyphIndexForCharacter(at: min(caret, length - 1))
            fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else { fragment = .zero }
        let height = max(fragment.height, layout.defaultLineHeight(for: font ?? EditorFontProvider.font()))
        let line = NSRect(x: bounds.minX, y: fragment.minY + textContainerOrigin.y, width: bounds.width, height: height)
        let brackets = matchingBrackets.filter { NSMaxRange($0) <= length && NSIntersectionRange($0, characters).length > 0 }.map { range in
            layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        return (line, brackets)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let now = decorations()
        if let line = now.line {
            TidepadTheme.currentLine.setFill()
            line.intersection(rect).fill()
        }
        for box in now.brackets where box.intersects(rect) {
            TidepadTheme.bracketFill.setFill()
            box.fill()
            TidepadTheme.bracketBorder.setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        appearanceChanged?()
    }
}
