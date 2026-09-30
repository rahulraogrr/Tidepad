import AppKit

/// Keeps Tidepad's session so nothing is lost when it quits or crashes, as Notepad++'s session snapshot
/// and VS Code's hot exit do: the open tabs in order, the selected tab, each tab's caret, whether the
/// terminal panel was open, and the text of every tab with unsaved changes (including Untitled tabs).
///
/// Unsaved text is written to backup files in ~/Library/Application Support/Tidepad/Session every
/// two seconds while something changes, so a crash loses at most that much. Quitting saves the session
/// without asking about unsaved tabs; they come back, still unsaved, the next time Tidepad starts.
/// Closing a tab still asks, and a tab saved or closed without saving drops its backup.
@MainActor final class SessionKeeper {
    struct State: Codable {
        struct Tab: Codable {
            var path: String?
            var name: String
            /// The backup file with the tab's unsaved text, if it has any.
            var backup: String?
            var encoding: UInt
            var byteOrderMark: Bool
            var lineEnding: String
            var language: String?
            /// The file's modification date and size when it was last loaded or saved, so a change
            /// made by another app while Tidepad was closed is still noticed.
            var modified: Date?
            var size: Int?
            var caret: Int
        }
        var tabs: [Tab] = []
        var selected: Int?
        var terminalVisible = false
    }

    let directory: URL
    private let manager: DocumentManager
    private let sessions: EditorSessionStore
    private let terminal: TerminalPanel
    private var timer: Timer?
    private var resignObserver: NSObjectProtocol?
    /// What was last saved, so the timer only writes when something changed.
    private var lastSignature = ""
    /// The revision of each document whose backup is on disk.
    private var backedUpRevision: [UUID: UInt64] = [:]
    /// Carets to restore when a restored tab's editor is first created.
    private var pendingCarets: [UUID: Int] = [:]

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tidepad", isDirectory: true).appendingPathComponent("Session", isDirectory: true)
    }

    init(manager: DocumentManager, sessions: EditorSessionStore, terminal: TerminalPanel, directory: URL? = nil) {
        self.manager = manager
        self.sessions = sessions
        self.terminal = terminal
        self.directory = directory ?? Self.defaultDirectory
    }

    private var stateFile: URL { directory.appendingPathComponent("session.json") }

    /// Saves every two seconds while something changed, and whenever Tidepad goes to the background.
    func startAutosave() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveIfChanged() }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.save() }
        }
    }

    func saveIfChanged() {
        if signature() != lastSignature { save() }
    }

    /// Changes that matter: tabs, their edits (revisions), files, encodings, the selected tab, the terminal.
    private func signature() -> String {
        let tabs = manager.documents.map { document in
            "\(document.id)|\(document.revision)|\(document.hasUnsavedChanges)|\(document.fileURL?.path ?? "")|"
                + "\(document.encoding.rawValue)|\(document.lineEnding.rawValue)|\(document.languageOverride?.rawValue ?? "")"
        }
        return tabs.joined(separator: ";") + "#\(manager.selectedID?.uuidString ?? "")#\(terminal.isVisible)"
    }

    /// Writes the session and the backups now. Returns false if anything couldn't be written.
    @discardableResult func save() -> Bool {
        let fm = FileManager.default
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return false }
        var state = State()
        var keep = Set<String>()
        var succeeded = true
        for document in manager.documents {
            let needsBackup = document.hasUnsavedChanges || (document.fileURL == nil && !document.text.isEmpty)
            guard document.fileURL != nil || needsBackup else { continue } // A blank Untitled tab has nothing to keep.
            var backup: String?
            if needsBackup {
                let name = document.id.uuidString + ".txt"
                let url = directory.appendingPathComponent(name)
                if backedUpRevision[document.id] != document.revision || !fm.fileExists(atPath: url.path) {
                    do {
                        try Data(document.text.utf8).write(to: url, options: .atomic)
                        backedUpRevision[document.id] = document.revision
                    } catch {
                        succeeded = false
                        NSLog("Tidepad: couldn't back up \(document.displayName): \(error)")
                    }
                }
                backup = name
                keep.insert(name)
            } else {
                backedUpRevision[document.id] = nil
            }
            state.tabs.append(State.Tab(path: document.fileURL?.path, name: document.displayName, backup: backup,
                                        encoding: document.encoding.rawValue, byteOrderMark: document.hasByteOrderMark,
                                        lineEnding: document.lineEnding.rawValue, language: document.languageOverride?.rawValue,
                                        modified: document.diskStamp?.modified, size: document.diskStamp?.size, caret: caret(of: document)))
            if document.id == manager.selectedID { state.selected = state.tabs.count - 1 }
        }
        state.terminalVisible = terminal.isVisible
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateFile, options: .atomic)
        } catch {
            succeeded = false
            NSLog("Tidepad: couldn't save the session: \(error)")
        }
        // Backups of tabs that were saved or closed are no longer needed.
        let files = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file.hasSuffix(".txt") && !keep.contains(file) {
            try? fm.removeItem(at: directory.appendingPathComponent(file))
        }
        if succeeded { lastSignature = signature() }
        return succeeded
    }

    private func caret(of document: EditorDocument) -> Int {
        if let session = sessions.existingSession(for: document) { return session.textView.selectedRange().location }
        return pendingCarets[document.id] ?? 0
    }

    /// Reopens the tabs from the last session, with their unsaved text, and the terminal panel.
    func restore() {
        guard let data = try? Data(contentsOf: stateFile), let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        var restored: [EditorDocument] = []
        var selectedIndex: Int?
        for (index, tab) in state.tabs.enumerated() {
            let url = tab.path.map { URL(fileURLWithPath: $0) }
            let document: EditorDocument
            if let backup = tab.backup, let text = try? String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8) {
                document = EditorDocument(fileURL: url, displayName: tab.name, text: text,
                                          encoding: String.Encoding(rawValue: tab.encoding), lineEnding: LineEnding(rawValue: tab.lineEnding))
                document.hasByteOrderMark = tab.byteOrderMark
                if tab.modified != nil || tab.size != nil { document.diskStamp = FileStamp(modified: tab.modified, size: tab.size) }
                document.markUnsaved()
            } else if let url, let loaded = try? TextFileService().open(url) {
                document = loaded.makeDocument()
            } else {
                continue // The file is gone and there was nothing unsaved.
            }
            document.languageOverride = tab.language.flatMap(SyntaxLanguage.init(rawValue:))
            if tab.caret > 0 { pendingCarets[document.id] = tab.caret }
            if state.selected == index { selectedIndex = restored.count }
            restored.append(document)
        }
        manager.restore(restored, selected: selectedIndex)
        if state.terminalVisible { terminal.show() }
        lastSignature = signature()
    }

    /// Puts a restored tab's caret back once its editor exists.
    func sessionCreated(_ session: EditorSession) {
        guard let caret = pendingCarets.removeValue(forKey: session.document.id) else { return }
        DispatchQueue.main.async {
            let location = min(caret, session.textView.textStorage?.length ?? 0)
            session.textView.setSelectedRange(NSRange(location: location, length: 0))
            session.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        }
    }
}
