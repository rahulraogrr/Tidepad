import AppKit
import Observation

/// One explicit route from menu actions to the selected document/session.
@MainActor @Observable final class WorkspaceCommandContext {
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored lazy var search = SearchController(context: self)
    /// Tools ▸ On-Device AI (Apple's on-device model).
    @ObservationIgnored lazy var ai = AIController(context: self)
    /// TidePad ▸ Check for Updates… and the weekly automatic check.
    @ObservationIgnored lazy var updates = UpdateController(preferences: preferences)
    let documents: DocumentManager
    let sessions: EditorSessionStore
    let preferences: EditorPreferences
    /// The folder open in the sidebar, if any.
    let project: ProjectFolder
    /// The terminal panel at the bottom of the window.
    let terminal: TerminalPanel
    @ObservationIgnored private var fontController: EditorFontPanelController?

    init(documents: DocumentManager, sessions: EditorSessionStore, preferences: EditorPreferences, project: ProjectFolder,
         terminal: TerminalPanel) {
        self.documents = documents
        self.sessions = sessions
        self.preferences = preferences
        self.project = project
        self.terminal = terminal
    }

    var document: EditorDocument? { documents.selectedDocument }
    /// The selected tab's NSTextView editor; nil for a large file (see `largeView`).
    var session: EditorSession? {
        guard let document, !document.isLarge else { return nil }
        return sessions.session(for: document)
    }
    var hasDocument: Bool { document != nil }
    /// The selected tab's large-file view, when it shows a large file.
    var largeView: LargeTextView? {
        guard let document, document.isLarge else { return nil }
        return sessions.existingLargeView(for: document)
    }

    /// Native title bar: the selected file's proxy icon (⌘-click for its path, drag to share) and the
    /// unsaved-changes dot in the close button.
    func syncWindowDocumentState() {
        window?.representedURL = document?.fileURL
        window?.isDocumentEdited = documents.documents.contains { $0.hasUnsavedChanges }
    }

    func save(asNew: Bool = false) {
        if let document { documents.save(document, saveAs: asNew) }
    }
    /// File ▸ Close Tab (⌘W). With another window in front (Settings, About, Search, On-Device AI),
    /// ⌘W closes that window instead, as everywhere on the Mac.
    func closeTab() {
        if let key = NSApp.keyWindow, let window, key !== window {
            key.performClose(nil)
            return
        }
        if let document { documents.close(document) } else { NSSound.beep() }
    }
    /// File ▸ Print (see DocumentPrinter).
    func printDocument() {
        guard let session else { return }
        DocumentPrinter.print(session, font: EditorFontProvider.font(configuration: preferences.displayOptions.font), window: window)
    }

    func find(_ action: NSTextFinder.Action) {
        switch action {
        case .nextMatch: search.navigate()
        case .previousMatch: search.navigate(backwards: true)
        case .showReplaceInterface: search.show(.replace)
        default: search.show(.find)
        }
    }

    // MARK: Encoding menu

    /// Encoding ▸ an encoding: the document is saved in it from now on (Notepad++'s "Convert to").
    /// The text itself doesn't change. If a character can't be written in the encoding, nothing
    /// changes and Tidepad says which one, so converting never loses text.
    func convertEncoding(to choice: TextEncodingChoice) {
        guard let document, !document.isLarge, document.encodingChoice != choice else { return }
        if let character = choice.firstUnwritableCharacter(in: document.text) {
            placeholder("Can’t Convert to \(choice.name)", detail: "“\(character)” can’t be written in \(choice.name), so converting would lose text. Choose an encoding that can hold every character, such as UTF-8.")
            return
        }
        document.encoding = choice.encoding
        document.hasByteOrderMark = choice.byteOrderMark
        document.markUnsaved()
    }

    /// Encoding ▸ Reopen with Encoding: reads the file again in another encoding, for a file whose
    /// encoding was guessed wrongly (Notepad++'s "Encode in"). Unsaved changes are lost, so it asks first.
    func reopen(with choice: TextEncodingChoice) {
        guard let document, !document.isLarge, document.fileURL != nil else { return }
        if document.hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "Reopen “\(document.displayName)” as \(choice.name)?"
            alert.informativeText = "Your unsaved changes to this document will be lost."
            alert.addButton(withTitle: "Reopen")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try documents.reloadFromDisk(document, as: choice) } catch {
            placeholder("Can’t Reopen as \(choice.name)", detail: "“\(document.displayName)” isn’t valid \(choice.name) text.")
        }
    }

    /// Encoding ▸ Line Endings: changes every line break in the document, as one undoable edit, and
    /// Return types the new one from then on.
    func convertLineEndings(to ending: LineEnding) {
        guard let session, let storage = session.textView.textStorage, session.textView.isEditable else { return }
        let text = storage.string
        let converted = ending.applied(to: text)
        if converted != text {
            let caret = min(session.textView.selectedRange().location, storage.length)
            let before = ending.applied(to: (text as NSString).substring(to: caret)) as NSString
            let edit = TextEdit(range: NSRange(location: 0, length: storage.length), text: converted,
                                selection: NSRange(location: before.length, length: 0), actionName: "Convert Line Endings")
            guard session.apply(edit) else { NSSound.beep(); return }
        }
        session.document.lineEnding = ending
        session.updateLineEnding()
    }

    func setLanguage(_ language: SyntaxLanguage?) {
        document?.languageOverride = language
        if let document {
            session?.setLanguage(document.syntaxLanguage)
            largeView?.setLanguage(document.syntaxLanguage)
        }
    }

    enum TextCommand {
        case duplicateLines, deleteLines, moveLinesUp, moveLinesDown
        case convertCase(CaseConversion), sortLines(ascending: Bool), removeDuplicateLines
        case formatJSON, formatXML, formatSQL
    }

    /// Runs an Edit/Tools command on the selected document as one undoable edit.
    /// Beeps when there is nothing to do (e.g. moving the first line up).
    @ObservationIgnored private var formatTask: Task<Void, Never>?

    func run(_ command: TextCommand) {
        switch command {
        case .formatJSON, .formatXML, .formatSQL: runFormat(command); return
        default: break
        }
        guard let session, let storage = session.textView.textStorage, session.textView.isEditable else { return }
        let text: NSString = storage.mutableString
        let selection = session.textView.selectedRange()
        let lineEnding = session.document.lineEnding.text
        let indent = String(repeating: " ", count: preferences.tabSize)
        do {
            let edit: TextEdit?
            switch command {
            case .duplicateLines: edit = TextCommands.duplicateLines(text, selection: selection, lineEnding: lineEnding)
            case .deleteLines: edit = TextCommands.deleteLines(text, selection: selection)
            case .moveLinesUp: edit = TextCommands.moveLines(text, selection: selection, up: true)
            case .moveLinesDown: edit = TextCommands.moveLines(text, selection: selection, up: false)
            case .convertCase(let conversion): edit = TextCommands.convertCase(text, selection: selection, to: conversion)
            case .sortLines(let ascending):
                edit = TextCommands.sortLines(text, selection: selection, ascending: ascending, lineEnding: lineEnding)
            case .removeDuplicateLines: edit = TextCommands.removeDuplicateLines(text, selection: selection, lineEnding: lineEnding)
            case .formatJSON: edit = try TextCommands.formatJSON(text, selection: selection, indent: indent, lineEnding: lineEnding)
            case .formatXML: edit = try TextCommands.formatXML(text, selection: selection, lineEnding: lineEnding)
            case .formatSQL: edit = try TextCommands.formatSQL(text, selection: selection, indent: indent, lineEnding: lineEnding)
            }
            guard let edit, session.apply(edit) else { NSSound.beep(); return }
        } catch {
            let title: String
            switch command {
            case .formatJSON: title = "Can’t Format JSON"
            case .formatXML: title = "Can’t Format XML"
            case .formatSQL: title = "Can’t Format SQL"
            default: title = "Command Failed"
            }
            placeholder(title, detail: error.localizedDescription)
        }
    }

    /// Formatting can take a while on large documents, so it runs in the background on a snapshot of the
    /// text, keeping Tidepad responsive. The result is applied (as one undo step) only if the document
    /// and selection are unchanged; otherwise it's discarded, like search results.
    private func runFormat(_ command: TextCommand) {
        guard let session, session.textView.isEditable else { return }
        let document = session.document
        let revision = document.revision
        let selection = session.textView.selectedRange()
        let text = document.text
        let lineEnding = document.lineEnding.text
        let indent = String(repeating: " ", count: preferences.tabSize)
        let title: String
        switch command {
        case .formatJSON: title = "Can’t Format JSON"
        case .formatXML: title = "Can’t Format XML"
        default: title = "Can’t Format SQL"
        }
        formatTask?.cancel()
        formatTask = Task { [weak self] in
            let started = ContinuousClock.now
            let result: Result<TextEdit?, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let source = text as NSString
                    switch command {
                    case .formatJSON: return try TextCommands.formatJSON(source, selection: selection, indent: indent, lineEnding: lineEnding)
                    case .formatXML: return try TextCommands.formatXML(source, selection: selection, lineEnding: lineEnding)
                    default: return try TextCommands.formatSQL(source, selection: selection, indent: indent, lineEnding: lineEnding)
                    }
                }
            }.value
            if EditorDiagnostics.enabled { print("PROFILE format compute: \(started.duration(to: .now))") }
            guard let self, !Task.isCancelled else { return }
            guard document.revision == revision, session.textView.selectedRange() == selection else {
                NSSound.beep() // The document changed while formatting; the result no longer applies.
                return
            }
            switch result {
            case .success(let edit):
                guard let edit else { NSSound.beep(); return }
                let applying = ContinuousClock.now
                if !session.apply(edit) { NSSound.beep() }
                if EditorDiagnostics.enabled { print("PROFILE format apply: \(applying.duration(to: .now))") }
            case .failure(let error):
                self.placeholder(title, detail: error.localizedDescription)
            }
        }
    }

    func applyDisplayOptions() { sessions.applyDisplayOptions(preferences.displayOptions) }
    func zoom(by amount: CGFloat) {
        preferences.fontSize = min(48, max(8, preferences.fontSize + amount))
        applyDisplayOptions()
    }
    func resetZoom() {
        preferences.fontSize = TidepadMetrics.editorFontSize
        applyDisplayOptions()
    }
    func setAppearance(_ appearance: EditorAppearance) {
        preferences.appearance = appearance
        NSApp.appearance = appearance.appearance
    }
    func showEditorFont() {
        if fontController == nil { fontController = EditorFontPanelController(context: self) }
        fontController?.show()
    }

    func placeholder(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        #if DEBUG
        MenuValidation.presenting(alert.window)
        #endif
        alert.runModal()
    }
}

@MainActor private final class EditorFontPanelController: NSObject {
    private weak var context: WorkspaceCommandContext?
    init(context: WorkspaceCommandContext) { self.context = context }
    func show() {
        guard let context else { return }
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(EditorFontProvider.font(configuration: context.preferences.displayOptions.font), isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }
    @objc func changeFont(_ sender: NSFontManager) {
        guard let context else { return }
        let current = EditorFontProvider.font(configuration: context.preferences.displayOptions.font)
        let selected = sender.convert(current)
        context.preferences.fontName = selected.fontName
        context.preferences.fontSize = min(48, max(8, selected.pointSize))
        context.applyDisplayOptions()
    }
}
