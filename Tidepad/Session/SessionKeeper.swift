import AppKit

/// Keeps Tidepad's session so nothing is lost when it quits or crashes, as Notepad++'s session snapshot
/// and VS Code's hot exit do: the open tabs in order, the selected tab, each tab's caret, whether the
/// terminal panel was open, and the text of every tab with unsaved changes (including Untitled tabs).
///
/// Unsaved text is written to backup files in ~/Library/Application Support/Tidepad/Session every
/// two seconds while something changes, so a crash loses at most that much. Quitting saves the session
/// without asking about unsaved tabs; they come back, still unsaved, the next time Tidepad starts.
/// Closing a tab still asks, and a tab saved or closed without saving drops its backup.
///
/// A large file's unsaved edits are kept as a journal (LargeTextBuffer.Journal): the ranges of the file
/// it keeps and the bytes typed or pasted, never a copy of the file. The journal names the version of
/// the file its ranges are in, and on APFS an instant clone of that version is kept beside it (it takes
/// no space until the original changes). At launch the edits are replayed over that exact version: the
/// file itself if it's unchanged, or the kept clone if another app (or "Keep TidePad's Version") changed
/// it. Only when neither is there does Tidepad say the edits couldn't be restored.
///
/// If the session file can't be read (damaged, or written by a newer TidePad), the session folder is
/// moved aside, never cleaned up, so no backup is lost.
@MainActor final class SessionKeeper {
    struct State: Codable {
        /// Bumped when the format changes in a way older versions can't read.
        static let currentVersion = 1
        var version = State.currentVersion
        struct Tab: Codable {
            var path: String?
            var name: String
            /// The backup file with the tab's unsaved text, if it has any.
            var backup: String?
            /// For a large file with unsaved edits: the journal (its data is in "<journal>-data").
            var journal: String?
            var encoding: UInt
            var byteOrderMark: Bool
            var lineEnding: String
            var language: String?
            /// The file's modification date and size when it was last loaded or saved, so a change
            /// made by another app while Tidepad was closed is still noticed.
            var modified: Date?
            var size: Int?
            var fileID: UInt64?
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
    /// For each large tab, the clone its kept copy was made from, and whether that worked.
    private var keptBases: [UUID: (clone: String, kept: Bool)] = [:]
    /// False when an unreadable session couldn't be moved aside: then nothing in the folder is deleted.
    private var cleanupAllowed = true
    /// Shows a message (an alert; checks replace it).
    var tell: (_ message: String, _ information: String) -> Void = { message, information in
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = information
            alert.runModal()
        }
    }

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
            var journalName: String?
            if let buffer = document.largeBuffer, document.hasUnsavedChanges {
                let name = document.id.uuidString + ".journal"
                let url = directory.appendingPathComponent(name), dataURL = directory.appendingPathComponent(name + "-data")
                keepBase(of: buffer.file, as: name, for: document.id)
                if backedUpRevision[document.id] != document.revision || !fm.fileExists(atPath: url.path) {
                    do {
                        let (journal, data) = buffer.journal()
                        try data.write(to: dataURL, options: .atomic)
                        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
                        backedUpRevision[document.id] = document.revision
                    } catch {
                        succeeded = false
                        NSLog("Tidepad: couldn't keep the edits to \(document.displayName): \(error)")
                    }
                }
                if fm.fileExists(atPath: url.path) { // Not when it couldn't be written at all.
                    journalName = name
                    keep.formUnion([name, name + "-data", name + "-base"])
                }
            }
            let needsBackup = !document.isLarge && (document.hasUnsavedChanges || (document.fileURL == nil && !document.text.isEmpty))
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
                if fm.fileExists(atPath: url.path) { // An older backup is better than none; a missing one isn't recorded.
                    backup = name
                    keep.insert(name)
                }
            } else if journalName == nil {
                backedUpRevision[document.id] = nil
            }
            state.tabs.append(State.Tab(path: document.fileURL?.path, name: document.displayName, backup: backup, journal: journalName,
                                        encoding: document.encoding.rawValue, byteOrderMark: document.hasByteOrderMark,
                                        lineEnding: document.lineEnding.rawValue, language: document.languageOverride?.rawValue,
                                        modified: document.diskStamp?.modified, size: document.diskStamp?.size,
                                        fileID: document.diskStamp?.fileID, caret: caret(of: document)))
            if document.id == manager.selectedID { state.selected = state.tabs.count - 1 }
        }
        state.terminalVisible = terminal.isVisible
        var stateWritten = false
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateFile, options: .atomic)
            stateWritten = true
        } catch {
            succeeded = false
            NSLog("Tidepad: couldn't save the session: \(error)")
        }
        // Backups of tabs that were saved or closed are no longer needed, once the session that no
        // longer lists them is safely written.
        if stateWritten && cleanupAllowed {
            let files = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files where Self.backupSuffixes.contains(where: { file.hasSuffix($0) }) && !keep.contains(file) {
                try? fm.removeItem(at: directory.appendingPathComponent(file))
            }
            keptBases = keptBases.filter { id, _ in manager.documents.contains { $0.id == id } }
        }
        if succeeded { lastSignature = signature() }
        return succeeded
    }

    static let backupSuffixes = [".txt", ".journal", ".journal-data", ".journal-base"]

    /// Keeps a clone of the file a large tab's journal refers to beside the journal ("<journal>-base"),
    /// so the edits can still be replayed if the file on disk changes. It's made again only when the
    /// tab's file is a new one (after saving, or reloading). Not on volumes without clones.
    private func keepBase(of file: LargeTextFile, as journal: String, for id: UUID) {
        guard let clone = file.clonePath else { return }
        let fm = FileManager.default
        let url = directory.appendingPathComponent(journal + "-base")
        if let done = keptBases[id], done.clone == clone, !done.kept || fm.fileExists(atPath: url.path) { return }
        // A journal from the previous file mustn't be paired with this one: it's written again.
        try? fm.removeItem(at: directory.appendingPathComponent(journal))
        try? fm.removeItem(at: url)
        backedUpRevision[id] = nil
        keptBases[id] = (clone, clonefile(clone, url.path, 0) == 0)
    }

    private func caret(of document: EditorDocument) -> Int {
        if let session = sessions.existingSession(for: document) { return session.textView.selectedRange().location }
        return pendingCarets[document.id] ?? 0
    }

    /// Reopens the tabs from the last session, with their unsaved text, and the terminal panel.
    func restore() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateFile.path) else { return }
        let state: State
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
            guard state.version <= State.currentVersion else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            // The backups can't be matched to tabs, so the autosave mustn't clean them up: the whole
            // folder is kept aside instead, and a new session starts.
            NSLog("Tidepad: couldn't read the session: \(error)")
            let aside = directory.deletingLastPathComponent()
                .appendingPathComponent("Session (not restored \(Self.asideDate.string(from: Date())))", isDirectory: true)
            if (try? fm.moveItem(at: directory, to: aside)) == nil { cleanupAllowed = false }
            tell("TidePad couldn't restore your last session.",
                 "Any unsaved text from it is kept in “\(cleanupAllowed ? aside.path : directory.path)”.")
            return
        }
        var restored: [EditorDocument] = []
        var selectedIndex: Int?
        var lostEdits: [String] = []
        for (index, tab) in state.tabs.enumerated() {
            let url = tab.path.map { URL(fileURLWithPath: $0) }
            let document: EditorDocument
            if let journal = tab.journal, let url, let edited = restoreLarge(url, journal: journal, tab: tab) {
                document = edited
            } else if tab.journal != nil, let url, let loaded = try? TextFileService().open(url) {
                lostEdits.append(tab.name) // The file changed (or the journal couldn't be read): open it as it is.
                document = loaded.makeDocument()
            } else if let backup = tab.backup, let text = try? String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8) {
                document = EditorDocument(fileURL: url, displayName: tab.name, text: text,
                                          encoding: String.Encoding(rawValue: tab.encoding), lineEnding: LineEnding(rawValue: tab.lineEnding))
                document.hasByteOrderMark = tab.byteOrderMark
                if tab.modified != nil || tab.size != nil { document.diskStamp = tab.stamp }
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
        if !lostEdits.isEmpty {
            tell("Unsaved changes to \(lostEdits.joined(separator: ", ")) couldn't be restored.",
                 "The file changed on disk after TidePad quit, so the changes no longer fit it. It's open as it is now.")
        }
    }

    /// A large file with its journal's edits, replayed over the version of the file they were made
    /// against: the file, if it's still that version, or the clone kept with the journal.
    private func restoreLarge(_ url: URL, journal name: String, tab: State.Tab) -> EditorDocument? {
        guard let journalData = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let journal = try? JSONDecoder().decode(LargeTextBuffer.Journal.self, from: journalData),
              let data = try? Data(contentsOf: directory.appendingPathComponent(name + "-data"), options: .alwaysMapped) else { return nil }
        // Journals from before 1.0 don't name their version: the one last seen is the best guess.
        let base = journal.base ?? tab.stamp
        var buffer: LargeTextBuffer?
        // The file itself, if it's that version and didn't change while it was cloned.
        if let file = try? LargeTextFile(url: url), file.identity == base, FileStamp(url) == file.identity {
            buffer = try? LargeTextBuffer(file: file, journal: journal, data: data)
        }
        let kept = directory.appendingPathComponent(name + "-base")
        if buffer == nil, FileManager.default.fileExists(atPath: kept.path), let file = try? LargeTextFile(url: url, contentsOf: kept) {
            buffer = try? LargeTextBuffer(file: file, journal: journal, data: data)
        }
        guard let buffer else { return nil }
        let document = OpenedFile.document(for: buffer)
        // The version on disk the user last saw: if the file is different now, TidePad asks about it as usual.
        document.diskStamp = tab.stamp
        document.markUnsaved()
        return document
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

extension SessionKeeper {
    private static let asideDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}

// Reading is forgiving: a missing key gets its default, so sessions from other versions of TidePad
// still open (the synthesized decoder would refuse the whole file).
extension SessionKeeper.State {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        tabs = try values.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
        selected = try values.decodeIfPresent(Int.self, forKey: .selected)
        terminalVisible = try values.decodeIfPresent(Bool.self, forKey: .terminalVisible) ?? false
    }
}

extension SessionKeeper.State.Tab {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        name = try values.decodeIfPresent(String.self, forKey: .name)
            ?? path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled"
        backup = try values.decodeIfPresent(String.self, forKey: .backup)
        journal = try values.decodeIfPresent(String.self, forKey: .journal)
        encoding = try values.decodeIfPresent(UInt.self, forKey: .encoding) ?? String.Encoding.utf8.rawValue
        byteOrderMark = try values.decodeIfPresent(Bool.self, forKey: .byteOrderMark) ?? false
        lineEnding = try values.decodeIfPresent(String.self, forKey: .lineEnding) ?? LineEnding.lf.rawValue
        language = try values.decodeIfPresent(String.self, forKey: .language)
        modified = try values.decodeIfPresent(Date.self, forKey: .modified)
        size = try values.decodeIfPresent(Int.self, forKey: .size)
        fileID = try values.decodeIfPresent(UInt64.self, forKey: .fileID)
        caret = try values.decodeIfPresent(Int.self, forKey: .caret) ?? 0
    }

    /// The file's stamp when the tab was last loaded or saved.
    var stamp: FileStamp { FileStamp(modified: modified, size: size, fileID: fileID) }
}
