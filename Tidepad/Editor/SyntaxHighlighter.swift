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
    /// Whether the painted range currently contains bold fonts that clearPaint must reset.
    private var boldApplied = false
    /// Links in the painted text, for ⌘-click.
    private var links: [(range: NSRange, url: URL)] = []
    private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// The regular editor font; keywords use its bold variant from NSFontManager.
    var baseFont: NSFont { didSet { boldFont = Self.bold(baseFont); stale = true } }
    private var boldFont: NSFont

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
        let tokens = engine.tokens(in: range, index: lineIndex, text: text)

        // Bold is a real font attribute on the text, as in Notepad++: the bold face of the editor font
        // from NSFontManager. Attribute-only storage changes don't register undo, dirty the document or
        // change the saved text, and monospaced bold faces keep the same advances, so lines don't
        // reflow. Resetting the previous bold runs and applying the new ones is one storage transaction.
        var bold: [NSRange] = []
        for token in tokens where SyntaxPalette.isBold(token.kind) {
            if let last = bold.last, NSMaxRange(last) == token.range.location {
                bold[bold.count - 1].length += token.range.length // Merge adjacent runs, e.g. ">=".
            } else { bold.append(token.range) }
        }
        let applyBold = !bold.isEmpty && boldFont != baseFont
        let previous = NSIntersectionRange(paintedRange, NSRange(location: 0, length: storage.length))
        if (boldApplied && previous.length > 0) || applyBold {
            storage.beginEditing()
            if boldApplied && previous.length > 0 { storage.addAttribute(.font, value: baseFont, range: previous) }
            if applyBold { for boldRange in bold { storage.addAttribute(.font, value: boldFont, range: boldRange) } }
            storage.endEditing()
        }
        boldApplied = applyBold

        if previous.length > 0 {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: previous)
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: previous)
        }
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let language = engine.language
        for token in tokens {
            layout.addTemporaryAttribute(.foregroundColor, value: SyntaxPalette.color(for: token.kind, language: language, dark: dark),
                                         forCharacterRange: token.range)
        }
        // Links keep their colour and are underlined, as Notepad++ shows clickable links.
        links = detectLinks(in: range, text: text)
        for link in links {
            layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: link.range)
        }
        paintedRange = range
        stale = false
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
        if boldApplied, range.length > 0, let storage = textView.textStorage {
            storage.beginEditing()
            storage.addAttribute(.font, value: baseFont, range: range)
            storage.endEditing()
        }
        boldApplied = false
        paintedRange = NSRange(location: 0, length: 0)
        stale = true
    }
}
