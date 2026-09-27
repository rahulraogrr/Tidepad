import AppKit

/// Draws bold syntax tokens (keywords, operators) by drawing their glyphs a second time, shifted
/// right by a fraction of a point. Temporary attributes can only change colour and underline, and
/// a real bold font would have to be stored in the text itself, affecting typing, undo and layout.
final class CodeLayoutManager: NSLayoutManager {
    /// Sorted, non-overlapping character ranges to embolden. Maintained by SyntaxHighlighter.
    var boldRanges: [NSRange] = []

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard !boldRanges.isEmpty, glyphsToShow.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let offset = max(0.4, (firstTextView?.font?.pointSize ?? 12) * 0.045)
        var index = firstRange(endingAfter: characters.location)
        while index < boldRanges.count && boldRanges[index].location < NSMaxRange(characters) {
            let overlap = NSIntersectionRange(boldRanges[index], characters)
            if overlap.length > 0 {
                let glyphs = glyphRange(forCharacterRange: overlap, actualCharacterRange: nil)
                NSGraphicsContext.saveGraphicsState()
                let shift = NSAffineTransform()
                shift.translateX(by: offset, yBy: 0)
                shift.concat()
                super.drawGlyphs(forGlyphRange: glyphs, at: origin)
                NSGraphicsContext.restoreGraphicsState()
            }
            index += 1
        }
    }

    /// Keeps bold ranges aligned with the text between an edit and the next highlighting pass.
    /// `editedRange` is in post-edit coordinates, as NSTextStorage reports it.
    func adjustBoldRanges(editedRange: NSRange, delta: Int) {
        guard !boldRanges.isEmpty else { return }
        let start = editedRange.location, oldEnd = NSMaxRange(editedRange) - delta
        boldRanges = boldRanges.compactMap { range in
            if NSMaxRange(range) <= start { return range }
            if range.location >= oldEnd { return NSRange(location: range.location + delta, length: range.length) }
            return nil // Touched by the edit; the next highlighting pass decides.
        }
    }

    private func firstRange(endingAfter location: Int) -> Int {
        var low = 0, high = boldRanges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(boldRanges[middle]) <= location { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
