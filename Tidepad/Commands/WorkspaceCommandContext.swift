import AppKit
import Observation

/// One explicit route from menu actions to the selected document/session.
@MainActor @Observable final class WorkspaceCommandContext {
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored lazy var search = SearchController(context: self)
    let documents: DocumentManager
    let sessions: EditorSessionStore
    let preferences: EditorPreferences
    @ObservationIgnored private var fontController: EditorFontPanelController?

    init(documents: DocumentManager, sessions: EditorSessionStore, preferences: EditorPreferences) {
        self.documents = documents
        self.sessions = sessions
        self.preferences = preferences
    }

    var document: EditorDocument? { documents.selectedDocument }
    var session: EditorSession? {
        guard let document else { return nil }
        return sessions.session(for: document)
    }
    var hasDocument: Bool { document != nil }

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
