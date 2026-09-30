import AppKit
import Combine

@MainActor final class EditorSession: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    let document: EditorDocument
    let scrollView: NSScrollView
    let textView: CodeTextView
    let ruler: LineNumberRulerView
    private var highlighter: SyntaxHighlighter?
    private var language: SyntaxLanguage
    let index = LineIndex()
    /// The regular editor font. Syntax bolding changes fonts in the text, so NSTextView.font may
    /// report a bold keyword's font; the gutter, typing and highlighter use this instead.
    private(set) var baseFont: NSFont
    private var appliedOptions: EditorDisplayOptions?
    /// Called when the selection changes (the Claude Code connection passes it on).
    var selectionChanged: ((EditorSession) -> Void)?

    init(document: EditorDocument, fontConfiguration: EditorFontConfiguration = .standard,
         syntaxPolicy: SyntaxPolicy = SyntaxPolicy()) {
        self.document = document
        language = document.syntaxLanguage
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        // Explicit TextKit 1 stack supports the ruler's glyph layout queries.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        layout.backgroundLayoutEnabled = false
        let container = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.lineFragmentPadding = TidepadMetrics.editorLineFragmentPadding
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), textContainer: container)
        ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        baseFont = EditorFontProvider.font(configuration: fontConfiguration)
        super.init()
        textView.font = baseFont
        ruler.textFont = baseFont
        textView.defaultParagraphStyle = EditorFontProvider.paragraphStyle(font: baseFont, configuration: fontConfiguration)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: TidepadMetrics.editorHorizontalInset, height: TidepadMetrics.editorVerticalInset)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.backgroundColor = TidepadTheme.editorBackground
        textView.textColor = TidepadTheme.editorText
        textView.insertionPointColor = TidepadTheme.caret
        scrollView.clipsToBounds = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        // Attach before loading text so AppKit grows the document in flipped clip coordinates.
        textView.string = document.text
        textView.setFrameOrigin(.zero)
        textView.delegate = self
        if let prepared = document.preparedLines { index.install(prepared); document.preparedLines = nil }
        else { index.rebuild(textView.string) }
        EditorDiagnostics.measure("gutter") { ruler.lineIndex = index }
        document.lineCount = index.starts.count
        document.utf16Length = storage.length
        updateLineEnding()
        updateCursor()
        highlighter = SyntaxHighlighter(textView: textView, lineIndex: index, baseFont: baseFont, policy: syntaxPolicy)
        highlighter?.update(language: language)
        textView.linkAt = { [weak self] characterIndex in self?.highlighter?.link(at: characterIndex) }
        storage.delegate = self
        document.saveBoundary = { [weak textView] in textView?.breakUndoCoalescing() }
        document.attachStorage(read: { [weak storage] in storage?.string ?? "" },
            replace: { [weak self] value in
                guard let self else { return }
                _ = self.applySearchReplacement(range: NSRange(location: 0, length: self.textView.textStorage?.length ?? 0), text: value)
            })
        textView.appearanceChanged = { [weak self] in
            self?.highlighter?.refresh()
            self?.ruler.needsDisplay = true
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func viewportChanged() {
        ruler.needsDisplay = true
        // No full redraw here: the clip view draws only the newly shown strip, and colour changes
        // invalidate their own text's display.
        highlighter?.renderVisibleText()
    }

    func revealSearchMatch(_ range: NSRange) {
        guard range.location != NSNotFound, NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    @discardableResult func goToLine(_ input: String) -> Bool {
        guard let line = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)),
              line >= 1, line <= index.starts.count else { return false }
        revealSearchMatch(NSRange(location: index.starts[line - 1], length: 0))
        return true
    }

    @discardableResult func applySearchReplacement(range: NSRange, text: String, selection: NSRange? = nil,
                                                   actionName: String = "Replace") -> Bool {
        guard textView.isEditable, let storage = textView.textStorage,
              NSMaxRange(range) <= storage.length else { return false }
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        defer { textView.undoManager?.endUndoGrouping(); textView.breakUndoCoalescing() }
        // Validate/register native undo exactly once. Direct storage editing avoids insertText's
        // forced layout/scroll to the end of a multi-megabyte replacement.
        guard EditorDiagnostics.measure("bulk undo registration", { textView.shouldChangeText(in: range, replacementString: text) }) else { return false }
        storage.beginEditing()
        EditorDiagnostics.measure("bulk storage mutation") { storage.replaceCharacters(in: range, with: text) }
        EditorDiagnostics.measure("bulk end editing") { storage.endEditing() }
        let caret = selection ?? NSRange(location: range.location + (text as NSString).length, length: 0)
        textView.setSelectedRange(NSRange(location: min(caret.location, storage.length), length: min(caret.length, max(0, storage.length - caret.location))))
        EditorDiagnostics.measure("bulk final refresh") { textView.didChangeText() }
        textView.undoManager?.setActionName(actionName)
        return true
    }

    /// Applies a text command's edit as one undoable step and keeps the result in view.
    @discardableResult func apply(_ edit: TextEdit) -> Bool {
        guard applySearchReplacement(range: edit.range, text: edit.text, selection: edit.selection,
                                     actionName: edit.actionName) else { return false }
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    /// The document's line ending follows its text; a document without line breaks keeps the one it
    /// has (a new tab's, or one chosen in Encoding ▸ Line Endings). Return types it.
    func updateLineEnding() {
        if index.starts.count > 1 { document.lineEnding = index.lineEnding }
        textView.lineBreak = document.lineEnding.text
    }

    func setLanguage(_ language: SyntaxLanguage) {
        self.language = language
        highlighter?.setLanguage(language)
    }

    func applyDisplayOptions(_ options: EditorDisplayOptions) {
        guard appliedOptions != options else { return }
        let previous = appliedOptions
        appliedOptions = options
        if previous?.font != options.font {
            let font = EditorFontProvider.font(configuration: options.font)
            let paragraph = EditorFontProvider.paragraphStyle(font: font, configuration: options.font)
            baseFont = font
            ruler.textFont = font
            highlighter?.baseFont = font
            textView.font = font
            textView.defaultParagraphStyle = paragraph
            textView.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
                range: NSRange(location: 0, length: (textView.textStorage?.length ?? 0)))
            textView.typingAttributes[.font] = font
            textView.typingAttributes[.paragraphStyle] = paragraph
            ruler.lineIndex = index
        }
        scrollView.rulersVisible = options.showLineNumbers
        if previous?.wordWrap != options.wordWrap, let container = textView.textContainer {
            scrollView.hasHorizontalScroller = !options.wordWrap
            textView.isHorizontallyResizable = !options.wordWrap
            container.widthTracksTextView = options.wordWrap
            if options.wordWrap {
                textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
                container.containerSize = NSSize(width: max(1, scrollView.contentSize.width - 2 * textView.textContainerInset.width),
                                                 height: CGFloat.greatestFiniteMagnitude)
            } else {
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        textView.minSize = scrollView.contentSize
        textView.sizeToFit()
        ruler.needsDisplay = true
        highlighter?.renderVisibleText()
    }

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        EditorDiagnostics.measure("incremental index") { index.applyEdit(in: storage.mutableString, range: range, delta: delta) }
        EditorDiagnostics.measure("invalidate snapshot") { document.recordEdit() }
        highlighter?.noteEdit(range: range, changeInLength: delta, length: storage.length)
    }

    private func restoreEditingState(_ state: UInt64) {
        let previous = document.editingState
        textView.undoManager?.registerUndo(withTarget: self) { target in target.restoreEditingState(previous) }
        document.setEditingState(state)
    }

    func textDidChange(_ notification: Notification) {
        if textView.undoManager?.isUndoing != true && textView.undoManager?.isRedoing != true {
            restoreEditingState(document.revision)
        }
        updateLineEnding()
        EditorDiagnostics.measure("gutter") { ruler.lineIndex = index }
        document.lineCount = index.starts.count
        document.utf16Length = textView.textStorage?.length ?? 0
        EditorDiagnostics.measure("status") { updateCursor() }
        EditorDiagnostics.measure("syntax invalidation") { highlighter?.update(language: language) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // New typing uses the regular font, even right after a bold keyword.
        if textView.typingAttributes[.font] as? NSFont != baseFont { textView.typingAttributes[.font] = baseFont }
        updateCursor()
        selectionChanged?(self)
    }

    private func updateCursor() {
        textView.updateCaretDecorations()
        document.selectionLength = textView.selectedRanges.reduce(0) { total, value in
            let range = value.rangeValue
            guard NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return total }
            return total + index.characters(in: range, text: textView.textStorage?.mutableString ?? NSMutableString())
        }
        let offset = min(textView.selectedRange().location, (textView.textStorage?.length ?? 0))
        let line = index.line(at: offset)
        document.cursorLine = line + 1
        let start = min(offset, index.starts[line])
        let prefix = (textView.textStorage?.mutableString ?? NSMutableString()).substring(with: NSRange(location: start, length: offset - start))
        document.cursorColumn = prefix.count + 1
    }
}

@MainActor final class EditorSessionStore: ObservableObject {
    private var sessions: [UUID: EditorSession] = [:]
    /// Opens files dropped on an editor.
    var openFiles: (([URL]) -> Void)?
    /// Called when the selection changes in any editor.
    var selectionChanged: ((EditorSession) -> Void)?
    /// Called when an editor is created for a tab (the session keeper puts its caret back).
    var sessionCreated: ((EditorSession) -> Void)?
    /// The tab's editor if it has been created, without creating one.
    func existingSession(for document: EditorDocument) -> EditorSession? { sessions[document.id] }
    private var largeViews: [UUID: LargeTextView] = [:]
    /// The large-file view for a large file's tab, created on first use and kept while the tab is open.
    func largeView(for document: EditorDocument, buffer: LargeTextBuffer, options: EditorDisplayOptions) -> LargeTextView {
        if let view = largeViews[document.id] { return view }
        let view = LargeTextView(document: document, buffer: buffer, options: options)
        largeViews[document.id] = view
        return view
    }
    func existingLargeView(for document: EditorDocument) -> LargeTextView? { largeViews[document.id] }
    func session(for document: EditorDocument) -> EditorSession {
        if let session = sessions[document.id] { return session }
        let session = EditorSession(document: document)
        session.textView.registerForDraggedTypes([.fileURL])
        session.textView.openFiles = { [weak self] urls in self?.openFiles?(urls) }
        session.selectionChanged = { [weak self] session in self?.selectionChanged?(session) }
        sessions[document.id] = session
        sessionCreated?(session)
        return session
    }
    func applyDisplayOptions(_ options: EditorDisplayOptions) {
        sessions.values.forEach { $0.applyDisplayOptions(options) }
        largeViews.values.forEach { $0.applyDisplayOptions(options) }
    }
    func retainDocuments(_ ids: Set<UUID>) {
        sessions = sessions.filter { ids.contains($0.key) }
        largeViews = largeViews.filter { ids.contains($0.key) }
    }
}
