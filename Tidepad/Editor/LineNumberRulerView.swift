import AppKit

final class LineNumberRulerView: NSRulerView {
    override var isFlipped: Bool { true }
    /// The regular editor font, set by EditorSession (NSTextView.font may be a bold keyword's font).
    var textFont: NSFont?
    var lineIndex = LineIndex() {
        didSet {
            let width = max(TidepadMetrics.gutterMinimumWidth, CGFloat(String(lineIndex.starts.count).count) * ("0" as NSString).size(withAttributes: [.font: textFont ?? EditorFontProvider.font()]).width + TidepadMetrics.gutterPadding + TidepadMetrics.gutterLeadingPadding)
            if ruleThickness != width { ruleThickness = width }
            needsDisplay = true
        }
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = TidepadMetrics.gutterMinimumWidth
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        TidepadTheme.gutterBackground.setFill()
        bounds.fill()
        TidepadTheme.separator.setFill()
        NSRect(x: bounds.maxX - TidepadMetrics.separatorWidth, y: bounds.minY, width: TidepadMetrics.separatorWidth, height: bounds.height).fill()
        guard let textView = clientView as? NSTextView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let visible = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let firstLine = lineIndex.line(at: chars.location)
        let lastLine = lineIndex.line(at: NSMaxRange(chars))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont ?? EditorFontProvider.font(), .foregroundColor: TidepadTheme.gutterText
        ]
        for line in firstLine...lastLine {
            let offset = lineIndex.starts[line]
            let fragment: NSRect
            if offset == (textView.textStorage?.length ?? 0) {
                fragment = layout.extraLineFragmentRect
            } else {
                let glyph = layout.glyphIndexForCharacter(at: offset)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let point = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView)
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - TidepadMetrics.gutterPadding, y: point.y), withAttributes: attributes)
        }
    }
}
