import AppKit
import Observation

/// One explicit route from menu actions to the selected document/session.
@MainActor @Observable final class WorkspaceCommandContext {
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored lazy var search = SearchController(context: self)
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
    var session: EditorSession? {
        guard let document else { return nil }
        return sessions.session(for: document)
    }
    var hasDocument: Bool { document != nil }

    /// Native title bar: the selected file's proxy icon (⌘-click for its path, drag to share) and the
    /// unsaved-changes dot in the close button.
    func syncWindowDocumentState() {
        window?.representedURL = document?.fileURL
        window?.isDocumentEdited = documents.documents.contains { $0.hasUnsavedChanges }
    }

    func save(asNew: Bool = false) {
        if let document { documents.save(document, saveAs: asNew) }
    }
    func closeTab() { if let document { documents.close(document) } }

    func find(_ action: NSTextFinder.Action) {
        switch action {
        case .nextMatch: search.navigate()
        case .previousMatch: search.navigate(backwards: true)
        case .showReplaceInterface: search.show(.replace)
        default: search.show(.find)
        }
    }

    func setLanguage(_ language: SyntaxLanguage?) {
        document?.languageOverride = language
        if let document { session?.setLanguage(document.syntaxLanguage) }
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
            case .formatSQL: edit = TextCommands.formatSQL(text, selection: selection, indent: indent, lineEnding: lineEnding)
            }
            guard let edit, session.apply(edit) else { NSSound.beep(); return }
        } catch {
            let title: String
            switch command {
            case .formatJSON: title = "Can’t Format JSON"
            case .formatXML: title = "Can’t Format XML"
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
                    default: return TextCommands.formatSQL(source, selection: selection, indent: indent, lineEnding: lineEnding)
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
