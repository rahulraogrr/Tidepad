import AppKit

/// Colours the visible text, Scintilla-style: the lazy engine lexes only as far as the viewport, so
/// file size doesn't matter. It re-colours after scrolling and edits, and finds links (URLs and email
/// addresses) in the visible text with NSDataDetector so they can be underlined and ⌘-clicked.
/// All work happens on the main actor, where the text storage is edited.
@MainActor final class SyntaxHighlighter: NSObject {
    private weak var textView: NSTextView?
    /// The editor's line index, which EditorSession keeps up to date before calling `noteEdit`.
    private let lineIndex: LineIndex
    private var engine = IncrementalSyntaxEngine()
    private let policy: SyntaxPolicy
    private var renderScheduled = false
    private var rendering = false
    /// The painted text no longer matches what's shown (edit, language, font or appearance change).
    private var stale = true
    private var paintedRange = NSRange(location: 0, length: 0)
    /// Whether any bold font has been put in the text (so a language change must reset fonts).
    private var boldUsed = false
    /// Links in the painted text, for ⌘-click.
    private var links: [(range: NSRange, url: URL)] = []
    private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// The regular editor font; keywords use its bold variant from NSFontManager.
    var baseFont: NSFont { didSet { boldFont = Self.bold(baseFont); stale = true } }
    private var boldFont: NSFont

    /// Time spent in each part of rendering, in nanoseconds (read by Tests/EditorPerformance.swift).
    static var timings: [String: UInt64] = [:]
    private static func timed<T>(_ part: String, _ body: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { timings[part, default: 0] += DispatchTime.now().uptimeNanoseconds - start }
        return body()
    }

    init(textView: NSTextView, lineIndex: LineIndex, baseFont: NSFont, policy: SyntaxPolicy = SyntaxPolicy()) {
        self.textView = textView
        self.lineIndex = lineIndex
        self.baseFont = baseFont
        self.boldFont = Self.bold(baseFont)
        self.policy = policy
        super.init()
    }

    private static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    /// Called after each change to the text, and when the language may have changed.
    func update(language: SyntaxLanguage) {
        if language != engine.language {
            clearPaint()
            engine.setLanguage(language)
        }
        stale = true
        scheduleRender()
    }

    func setLanguage(_ language: SyntaxLanguage) { update(language: language) }

    /// Re-colours everything visible, e.g. after a light/dark appearance change.
    func refresh() {
        stale = true
        renderVisibleText()
    }

    /// Called from the text storage's didProcessEditing, after the line index has been updated.
    func noteEdit(range editedRange: NSRange, changeInLength delta: Int, length: Int) {
        // The line before may have changed too (a CR joined with an inserted LF).
        engine.invalidate(fromLine: lineIndex.line(at: editedRange.location) - 1)
        links = []
        stale = true
        // Temporary attributes shift with edits. Cover both the old and shifted painted span, so the
        // next render removes all of it. Layout still has pre-edit glyphs here, so nothing is drawn yet.
        guard paintedRange.length > 0 else { return }
        let start = min(paintedRange.location, editedRange.location)
        let end = min(length, NSMaxRange(paintedRange) + max(0, delta))
        paintedRange = NSRange(location: start, length: max(0, end - start))
    }

    /// The link at a character index, if one is shown there.
    func link(at characterIndex: Int) -> URL? {
        links.first { NSLocationInRange(characterIndex, $0.range) }?.url
    }

    /// Coalesces the renders several changes in one event would ask for into one.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.renderVisibleText()
        }
    }

    func renderVisibleText() {
        guard !rendering, let textView, let layout = textView.layoutManager,
              let container = textView.textContainer, let storage = textView.textStorage else { return }
        let enabled = policy.isEnabled && storage.length <= policy.maximumUTF16Length
        guard enabled else { clearPaint(); return }
        // Don't change fonts under text being composed with an input method; its commit re-renders.
        guard !textView.hasMarkedText() else { return }
        let visible = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible.insetBy(dx: 0, dy: -100), in: container)
        var range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        range.length = min(range.length, policy.maximumPaintLength)
        if !stale && range == paintedRange { return }
        rendering = true
        defer { rendering = false }
        let text = storage.mutableString
        let previous = NSIntersectionRange(paintedRange, NSRange(location: 0, length: storage.length))

        // When only the view moved, the lines still in range are already painted: only the lines newly
        // in range are coloured, and colours come off only the lines that left. Re-painting everything
        // on every scroll step cost about 25 ms on a 10 MB JSON file (and redrew the whole screen
        // instead of the newly shown strip). After an edit, or a language, font or appearance change
        // (`stale`), everything in range is done again.
        let overlap = stale ? NSRange(location: range.location, length: 0) : NSIntersectionRange(previous, range)
        let incremental = overlap.length > 0
        let fresh = incremental ? Self.parts(of: range, outside: overlap) : [range]
        let gone = incremental ? Self.parts(of: previous, outside: overlap) : (previous.length > 0 ? [previous] : [])

        Self.timed("3 colours") {
            for part in gone {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: part)
                layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: part)
            }
        }
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let language = engine.language
        var newLinks: [(range: NSRange, url: URL)] = []
        for part in fresh where part.length > 0 {
            let tokens = Self.timed("1 tokens") { engine.tokens(in: part, index: lineIndex, text: text) }
            Self.timed("2 fonts") { applyBold(tokens, in: part, storage: storage) }
            Self.timed("3 colours") {
                for token in tokens {
                    layout.addTemporaryAttribute(.foregroundColor, value: SyntaxPalette.color(for: token.kind, language: language, dark: dark),
                                                 forCharacterRange: token.range)
                }
            }
            // Links keep their colour and are underlined, as Notepad++ shows clickable links. They're
            // looked for in whole paragraphs, so one isn't cut in two where the part starts or ends.
            Self.timed("4 links") {
                let paragraphs = NSIntersectionRange(text.paragraphRange(for: part), range)
                for link in detectLinks(in: paragraphs, text: text)
                where NSIntersectionRange(link.range, part).length > 0 && !newLinks.contains(where: { NSEqualRanges($0.range, link.range) }) {
                    newLinks.append(link)
                    layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: link.range)
                }
            }
        }
        let kept = incremental ? links.filter { link in
            NSIntersectionRange(link.range, range).length == link.range.length
                && !newLinks.contains { NSEqualRanges($0.range, link.range) }
        } : []
        links = kept + newLinks
        paintedRange = range
        stale = false
    }

    /// The parts of `outer` before and after `inner` (which lies inside it).
    private static func parts(of outer: NSRange, outside inner: NSRange) -> [NSRange] {
        [NSRange(location: outer.location, length: max(0, inner.location - outer.location)),
         NSRange(location: NSMaxRange(inner), length: max(0, NSMaxRange(outer) - NSMaxRange(inner)))].filter { $0.length > 0 }
    }

    /// Bold is a real font attribute on the text, as in Notepad++: the bold face of the editor font from
    /// NSFontManager. Attribute-only storage changes don't register undo, dirty the document or change
    /// the saved text, and monospaced bold faces keep the same advances, so lines don't reflow.
    ///
    /// Only characters whose font is wrong are changed. A font change makes TextKit lay that text out
    /// again, and with non-contiguous layout, changing text far above the screen means laying out
    /// everything in between: resetting the previous screen's bold after ⌘↓ took 2 s on a 10 MB file.
    /// So bold stays on text that scrolls away (it moves with the text if edits happen elsewhere), and
    /// text already right is left alone.
    private func applyBold(_ tokens: [SyntaxToken], in part: NSRange, storage: NSTextStorage) {
        var bold: [NSRange] = []
        for token in tokens where SyntaxPalette.isBold(token.kind) {
            if let last = bold.last, NSMaxRange(last) >= token.range.location {
                bold[bold.count - 1].length = max(NSMaxRange(last), NSMaxRange(token.range)) - last.location // Merge, e.g. ">=".
            } else { bold.append(token.range) }
        }
        guard boldFont != baseFont && (boldUsed || !bold.isEmpty) else { return }
        var runs: [(range: NSRange, bold: Bool)] = []
        var cursor = part.location
        for run in bold {
            if run.location > cursor { runs.append((NSRange(location: cursor, length: run.location - cursor), false)) }
            runs.append((run, true))
            cursor = NSMaxRange(run)
        }
        if NSMaxRange(part) > cursor { runs.append((NSRange(location: cursor, length: NSMaxRange(part) - cursor), false)) }
        var editing = false
        for run in runs where run.range.length > 0 && NSMaxRange(run.range) <= storage.length {
            let wanted = run.bold ? boldFont : baseFont
            var effective = NSRange()
            let current = storage.attribute(.font, at: run.range.location, longestEffectiveRange: &effective, in: run.range) as? NSFont
            if current == wanted && NSEqualRanges(effective, run.range) { continue }
            if !editing { storage.beginEditing(); editing = true }
            storage.addAttribute(.font, value: wanted, range: run.range)
        }
        if editing { storage.endEditing() }
        if !bold.isEmpty { boldUsed = true }
    }

    /// URLs and email addresses in `range`, found by NSDataDetector.
    private func detectLinks(in range: NSRange, text: NSString) -> [(range: NSRange, url: URL)] {
        guard let linkDetector, range.length > 0 else { return [] }
        let chunk = text.substring(with: range)
        let matches = linkDetector.matches(in: chunk, options: [], range: NSRange(location: 0, length: range.length))
        return matches.compactMap { result -> (range: NSRange, url: URL)? in
            guard let url = result.url, let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ftp", "mailto"].contains(scheme) else { return nil }
            return (range: NSRange(location: result.range.location + range.location, length: result.range.length), url: url)
        }
    }

    private func clearPaint() {
        links = []
        guard let textView else { return }
        let length = (textView.textStorage?.length ?? 0)
        let range = NSIntersectionRange(paintedRange, NSRange(location: 0, length: length))
        if range.length > 0 {
            textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            textView.layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        }
        // Bold may be anywhere text was shown (see renderVisibleText): back to the regular face everywhere.
        if boldUsed, let storage = textView.textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        boldUsed = false
        paintedRange = NSRange(location: 0, length: 0)
        stale = true
    }
}
