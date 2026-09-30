import AppKit
import Observation

/// Connects Claude Code to Tidepad, the way it connects to VS Code: Claude Code sees the open folder,
/// the open tabs and the current selection, can open files, and shows proposed changes for review.
/// In the terminal panel `claude` connects by itself; in another terminal, run `/ide` in Claude Code.
@MainActor @Observable final class ClaudeCodeConnection: IDEHost {
    /// How many Claude Code sessions are connected.
    private(set) var connectedClients = 0
    @ObservationIgnored let server: IDEServer
    @ObservationIgnored private let manager: DocumentManager
    @ObservationIgnored private let sessions: EditorSessionStore
    @ObservationIgnored private let project: ProjectFolder
    @ObservationIgnored private var latest: IDESelection?
    @ObservationIgnored private var reviews: [String: DiffReviewWindow] = [:]
    @ObservationIgnored private var selectionTask: Task<Void, Never>?

    /// `server` is for checks, which use a separate settings folder; the app uses ~/.claude.
    init(manager: DocumentManager, sessions: EditorSessionStore, project: ProjectFolder, server: IDEServer? = nil) {
        self.manager = manager
        self.sessions = sessions
        self.project = project
        let server = server ?? IDEServer()
        self.server = server
        server.host = self
        server.connectionsChanged = { [weak self] count in self?.connectedClients = count }
    }

    func start() {
        do { try server.start() } catch { NSLog("Tidepad: the Claude Code connection couldn't start: \(error)") }
        folderChanged()
    }

    func stop() { server.stop() }

    /// The open folder is the workspace Claude Code sees.
    func folderChanged() { server.workspaceFolders = project.url.map { [$0.path] } ?? [] }

    /// For shells in the terminal panel: tells `claude` where Tidepad is, so it connects automatically.
    var terminalEnvironment: [String: String] {
        guard let port = server.port else { return [:] }
        return ["CLAUDE_CODE_SSE_PORT": String(port), "ENABLE_IDE_INTEGRATION": "true"]
    }

    /// Tells Claude Code about the new selection, at most every 100 ms while it changes.
    func selectionChanged(in session: EditorSession) {
        selectionTask?.cancel()
        selectionTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self, let session, let selection = Self.selection(in: session) else { return }
            if !selection.isEmpty { self.latest = selection }
            self.server.broadcast("selection_changed", params: selection.json)
        }
    }

    static func selection(in session: EditorSession) -> IDESelection? {
        guard let url = session.document.fileURL, let storage = session.textView.textStorage else { return nil }
        let text = storage.mutableString
        let range = session.textView.selectedRange()
        guard NSMaxRange(range) <= text.length else { return nil }
        let index = session.index
        func point(_ offset: Int) -> (line: Int, character: Int) {
            let line = index.line(at: offset)
            return (line, offset - index.starts[line])
        }
        let start = point(range.location), end = point(NSMaxRange(range))
        return IDESelection(text: text.substring(with: range), filePath: url.path,
                            startLine: start.line, startCharacter: start.character, endLine: end.line, endCharacter: end.character)
    }

    /// The range for openFile: from `startText` (to the end of `endText`), or lines (1-based).
    static func range(in text: NSString, index: LineIndex, startLine: Int?, endLine: Int?, startText: String?, endText: String?) -> NSRange? {
        if let startText, !startText.isEmpty {
            let start = text.range(of: startText)
            guard start.location != NSNotFound else { return nil }
            if let endText, !endText.isEmpty {
                let end = text.range(of: endText, options: [], range: NSRange(location: start.location, length: text.length - start.location))
                if end.location != NSNotFound { return NSRange(location: start.location, length: NSMaxRange(end) - start.location) }
            }
            return start
        }
        guard let startLine, !index.starts.isEmpty else { return nil }
        let first = min(max(1, startLine), index.starts.count) - 1
        let last = min(max(first + 1, endLine ?? startLine), index.starts.count) - 1
        let end = last + 1 < index.starts.count ? index.starts[last + 1] : text.length
        return NSRange(location: index.starts[first], length: end - index.starts[first])
    }

    private func document(at path: String) -> EditorDocument? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return manager.documents.first { $0.fileURL?.standardizedFileURL == url }
    }

    // MARK: IDEHost

    func openFile(path: String, startLine: Int?, endLine: Int?, startText: String?, endText: String?, makeFrontmost: Bool) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return "File not found: \(path)" }
        let previous = manager.selectedID
        manager.open([URL(fileURLWithPath: path)])
        guard let document = document(at: path) else { return "Couldn't open \(path)" }
        if document.isLarge {
            // A large file: show its tab and go to the line; text ranges would mean searching 500 MB.
            manager.selectedID = makeFrontmost ? document.id : (previous ?? document.id)
            if makeFrontmost, let line = startLine {
                DispatchQueue.main.async { [weak self] in self?.sessions.existingLargeView(for: document)?.goToLine(line) }
            }
            return nil
        }
        guard makeFrontmost else {
            manager.selectedID = previous ?? document.id
            return nil
        }
        manager.selectedID = document.id
        let session = sessions.session(for: document)
        if let text = session.textView.textStorage?.mutableString,
           let range = Self.range(in: text, index: session.index, startLine: startLine, endLine: endLine, startText: startText, endText: endText) {
            // After SwiftUI shows the tab.
            DispatchQueue.main.async {
                session.textView.setSelectedRange(range)
                session.textView.scrollRangeToVisible(range)
            }
        }
        return nil
    }

    func currentSelection() -> IDESelection? {
        manager.selectedDocument.flatMap { $0.isLarge ? nil : Self.selection(in: sessions.session(for: $0)) }
    }

    func latestSelection() -> IDESelection? { latest ?? currentSelection() }

    func openTabs() -> [IDEEditorTab] {
        manager.documents.map { document in
            IDEEditorTab(path: document.fileURL?.path, label: document.displayName,
                         languageID: document.syntaxLanguage == .plain ? "plaintext" : document.syntaxLanguage.rawValue,
                         isActive: document.id == manager.selectedID, isDirty: document.hasUnsavedChanges)
        }
    }

    func workspaceFolders() -> [String] { project.url.map { [$0.path] } ?? [] }

    func documentState(path: String) -> (isOpen: Bool, isDirty: Bool, isUntitled: Bool) {
        guard let document = document(at: path) else { return (false, false, false) }
        return (true, document.hasUnsavedChanges, document.fileURL == nil)
    }

    func saveDocument(path: String) -> Bool {
        guard let document = document(at: path) else { return false }
        return manager.save(document)
    }

    func reviewDiff(oldPath: String, newPath: String, newContents: String, tabName: String,
                    decided: @escaping @MainActor (Bool, String) -> Void) {
        // Compare with what's in the editor if the file is open (it may have unsaved edits), else the file.
        let open = document(at: oldPath)
        let old = (open?.isLarge == false ? open?.text : nil) ?? (try? String(contentsOfFile: oldPath, encoding: .utf8)) ?? ""
        reviews[tabName]?.dismiss()
        let review = DiffReviewWindow(tabName: tabName, path: newPath, old: old, new: newContents) { [weak self] accepted in
            self?.reviews[tabName] = nil
            decided(accepted, newContents)
        }
        reviews[tabName] = review
        review.show()
    }

    func closeDiff(tabName: String) -> Bool {
        guard let review = reviews[tabName] else { return false }
        review.dismiss()
        return true
    }

    func closeAllDiffs() -> Int {
        let open = Array(reviews.values)
        open.forEach { $0.dismiss() }
        return open.count
    }
}
