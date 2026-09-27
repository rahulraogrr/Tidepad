import AppKit

/// Its text storage is exclusively edited on the main actor; AppKit’s delegate predates isolation.
/// AppKit adapter. The lexer/cache have no dependency on views, documents, or colors.
@MainActor final class SyntaxHighlighter: NSObject, @preconcurrency NSTextStorageDelegate {
    private weak var textView: NSTextView?
    private var engine = IncrementalSyntaxEngine()
    private var language = SyntaxLanguage.plain
    private let policy: SyntaxPolicy
    private var pending: Task<Void, Never>?
    private var worker: Task<IncrementalSyntaxEngine, Never>?
    private var revision = 0
    private var ready = false
    private var rendering = false
    private var paintedRange = NSRange(location: 0, length: 0)

    init(textView: NSTextView, policy: SyntaxPolicy = SyntaxPolicy()) {
        self.textView = textView
        self.policy = policy
        super.init()
    }

    deinit { pending?.cancel(); worker?.cancel() }

    func update(language: SyntaxLanguage) {
        self.language = language
        revision += 1
        let requestedRevision = revision
        pending?.cancel()
        worker?.cancel()
        ready = false
        guard let textView else { return }
        guard policy.isEnabled, language != .plain,
              EditorPerformanceMode(utf16Length: textView.textStorage?.length ?? 0).permitsSyntax,
              (textView.textStorage?.length ?? 0) <= policy.maximumUTF16Length else {
            clearPaint()
            engine = IncrementalSyntaxEngine()
            return
        }
        let delay = policy.debounceNanoseconds
        pending = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, let textView = self.textView, !Task.isCancelled else { return }
            let snapshot = textView.string
            let previous = self.engine
            let job = Task.detached(priority: .utility) {
                var next = previous
                next.update(text: snapshot, language: language)
                return next
            }
            self.worker = job
            let result = await job.value
            guard !Task.isCancelled, self.revision == requestedRevision else { return }
            self.engine = result
            self.ready = true
            self.renderVisibleText()
        }
    }

    func setLanguage(_ language: SyntaxLanguage) {
        if self.language != language { clearPaint(); update(language: language) }
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Temporary attributes shift with edits. Cover both the old and shifted painted span.
        ready = false
        guard paintedRange.length > 0 else { return }
        let start = min(paintedRange.location, editedRange.location)
        let end = min(textStorage.length, NSMaxRange(paintedRange) + max(0, delta))
        // Layout still has pre-edit glyphs here. Defer attribute invalidation until the completed highlighting pass.
        paintedRange = NSRange(location: start, length: max(0, end - start))
    }

    func renderVisibleText() {
        guard ready, !rendering, let textView, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        rendering = true
        defer { rendering = false }
        clearPaint()
        let visible = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible.insetBy(dx: 0, dy: -100), in: container)
        var range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        range.length = min(range.length, policy.maximumPaintLength)
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for token in engine.tokens(in: range) {
            layout.addTemporaryAttribute(.foregroundColor, value: SyntaxPalette.color(for: token.kind, dark: dark),
                                         forCharacterRange: token.range)
        }
        paintedRange = range
    }

    private func clearPaint() {
        guard let textView else { return }
        let length = (textView.textStorage?.length ?? 0)
        let range = NSIntersectionRange(paintedRange, NSRange(location: 0, length: length))
        if range.length > 0 { textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range) }
        paintedRange = NSRange(location: 0, length: 0)
    }
}
