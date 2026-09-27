import AppKit

final class CodeTextView: NSTextView {
    var matchingBrackets: [NSRange] = []
    var appearanceChanged: (() -> Void)?

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
