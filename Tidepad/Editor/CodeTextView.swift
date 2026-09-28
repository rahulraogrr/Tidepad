import AppKit

final class CodeTextView: NSTextView {
    /// What Return types: the document's line break, so a Windows (CRLF) file stays CRLF, as in Notepad++.
    var lineBreak = "\n"
    var matchingBrackets: [NSRange] = []
    var appearanceChanged: (() -> Void)?
    /// Opens files dropped on the editor, as Notepad++ does, instead of inserting their paths.
    var openFiles: (([URL]) -> Void)?
    /// The link shown at a character index, if any. ⌘-click opens it with its default app.
    var linkAt: ((Int) -> URL?)?

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

    func updateCaretDecorations() {
        let selection = selectedRange()
        matchingBrackets = selection.length == 0
            ? BracketMatcher.match(in: textStorage?.mutableString ?? NSMutableString(), caret: selection.location) : []
        setNeedsDisplay(visibleRect)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer else { return }
        let length = (textStorage?.length ?? 0)
        let caret = min(selectedRange().location, length)
        let visible = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // An offscreen caret must not make a cosmetic highlight lay out the entire intervening file.
        guard caret >= characters.location, caret <= NSMaxRange(characters) else { return }
        let fragment: NSRect
        if caret == length && (length == 0 || layout.extraLineFragmentTextContainer != nil) {
            fragment = layout.extraLineFragmentRect
        } else if length > 0 {
            let glyph = layout.glyphIndexForCharacter(at: min(caret, length - 1))
            fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else { fragment = .zero }
        let height = max(fragment.height, layout.defaultLineHeight(for: font ?? EditorFontProvider.font()))
        let line = NSRect(x: visibleRect.minX, y: fragment.minY + textContainerOrigin.y,
                          width: visibleRect.width, height: height)
        TidepadTheme.currentLine.setFill()
        line.intersection(rect).fill()
        for range in matchingBrackets where NSMaxRange(range) <= length && NSIntersectionRange(range, characters).length > 0 {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            guard box.intersects(rect) else { continue }
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
