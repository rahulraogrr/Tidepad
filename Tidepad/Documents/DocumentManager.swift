import AppKit
import Observation

@MainActor @Observable final class DocumentManager {
    var documents: [EditorDocument] = []
    var selectedID: UUID?
    var recentFiles: [URL] = NSDocumentController.shared.recentDocumentURLs
    private let files = TextFileService()
    var selectedDocument: EditorDocument? { documents.first { $0.id == selectedID } }
    @ObservationIgnored private var presenters: [UUID: DocumentFilePresenter] = [:]
    /// Documents whose files changed on disk and still need the user's decision.
    @ObservationIgnored private(set) var pendingExternalChanges: Set<UUID> = []
    @ObservationIgnored private var reviewingExternalChanges = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var folderWatcher: FolderWatcher?
    @ObservationIgnored private var watchedFolders: Set<String> = []

    init() {
        newDocument()
        // Changes made while Tidepad is in the background are reviewed when it becomes active,
        // like Notepad++'s "modified by another program" check.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOpenFilesOnDisk() }
        }
    }

    /// NSFilePresenter only hears about coordinated writes; tools like `echo >>`, git or rsync write
    /// without coordination. So, like NSDocument, also compare each open file's modification date and
    /// size when Tidepad becomes active. One stat per open file; contents aren't read.
    func checkOpenFilesOnDisk() {
        for document in documents {
            guard let url = document.fileURL else { continue }
            if FileStamp(url) != document.diskStamp { pendingExternalChanges.insert(document.id) }
        }
        reviewExternalChanges()
    }

    /// The first free name of "Untitled", "Untitled 2", "Untitled 3"…, so closed tabs' numbers are
    /// reused, as in TextEdit and Notepad++.
    static func untitledName(notIn names: Set<String>) -> String {
        var number = 1
        while names.contains(number == 1 ? "Untitled" : "Untitled \(number)") { number += 1 }
        return number == 1 ? "Untitled" : "Untitled \(number)"
    }

    func newDocument() {
        let names = Set(documents.filter { $0.fileURL == nil }.map(\.displayName))
        let document = EditorDocument(displayName: Self.untitledName(notIn: names))
        documents.append(document)
        selectedID = document.id
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose text files to open in Tidepad."
        #if DEBUG
        MenuValidation.presenting(panel)
        #endif
        guard panel.runModal() == .OK else { return }
        openInBackground(panel.urls)
    }

    func openInBackground(_ urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                if let existing = documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
                    selectedID = existing.id; continue
                }
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) { try TextFileService().load(url) }.value
                    acceptOpened(loaded.makeDocument())
                } catch { show(error) }
            }
        }
    }

    func open(_ urls: [URL]) {
        for url in urls {
            if let existing = documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
                selectedID = existing.id
                continue
            }
            do {
                let document = try files.read(url)
                documents.append(document)
                selectedID = document.id
                watch(document)
                noteRecent(url)
            } catch { show(error) }
        }
    }

    /// Adds the tabs of the last session (see SessionKeeper), replacing the blank Untitled tab a new
    /// window starts with. Files already open (e.g. opened from Finder at launch) aren't added twice.
    func restore(_ restored: [EditorDocument], selected: Int?) {
        guard !restored.isEmpty else { return }
        documents.removeAll { $0.fileURL == nil && !$0.hasUnsavedChanges && $0.text.isEmpty }
        var chosen: EditorDocument?
        for (index, document) in restored.enumerated() {
            if let url = document.fileURL, documents.contains(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) { continue }
            documents.append(document)
            watch(document)
            if index == selected { chosen = document }
        }
        if let chosen { selectedID = chosen.id }
        else if !documents.contains(where: { $0.id == selectedID }) { selectedID = documents.last?.id }
    }

    func acceptOpened(_ document: EditorDocument) {
        if let url = document.fileURL, let existing = documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            selectedID = existing.id; return
        }
        documents.append(document); selectedID = document.id
        watch(document)
        if let url = document.fileURL { noteRecent(url) }
    }

    @discardableResult func save(_ document: EditorDocument, saveAs: Bool = false) -> Bool {
        var destination = document.fileURL
        if saveAs || destination == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = document.fileURL?.lastPathComponent ?? "\(document.displayName).txt"
            panel.directoryURL = document.fileURL?.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let destination else { return false }
        if documents.contains(where: { $0.id != document.id && $0.fileURL?.standardizedFileURL == destination.standardizedFileURL }) {
            let alert = NSAlert()
            alert.messageText = "This file is already open in another tab."
            alert.informativeText = "Choose another filename to keep both documents separate."
            alert.runModal()
            return false
        }
        // A coordinated write, so other apps' file presenters are told, and ours isn't.
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: presenters[document.id]).coordinate(
            writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
            do { try files.write(document, to: url) } catch { writeError = error }
        }
        if let error = writeError ?? coordinationError {
            show(error)
            return false
        }
        let moved = document.fileURL?.standardizedFileURL != destination.standardizedFileURL
        document.markSaved(at: destination)
        document.diskStamp = FileStamp(destination)
        pendingExternalChanges.remove(document.id)
        // Keep the same presenter for a normal save: a new one could receive this save's own change
        // notification, which is delivered after the coordinated write finishes.
        if moved || presenters[document.id] == nil { watch(document) }
        noteRecent(destination)
        return true
    }

    func close(_ document: EditorDocument) {
        guard confirmClose(document), let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        unwatch(document.id)
        if selectedID == document.id {
            selectedID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
        }
    }

    func saveAll() {
        let original = selectedID
        // Return to the tab the user was on, even if a Save panel is cancelled part-way.
        defer { selectedID = original }
        // Blank Untitled tabs have nothing to save, so they don't get a Save panel.
        for document in documents where document.hasUnsavedChanges {
            selectedID = document.id
            guard save(document) else { return }
        }
    }

    func closeAll(except retainedID: UUID? = nil) {
        let targets = documents.filter { $0.id != retainedID }
        let original = selectedID
        for document in targets {
            selectedID = document.id
            guard confirmClose(document) else { return }
        }
        let closing = Set(targets.map(\.id))
        documents.removeAll { closing.contains($0.id) }
        closing.forEach(unwatch)
        selectedID = documents.contains(where: { $0.id == original }) ? original : documents.first?.id
    }

    func clearRecentFiles() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentFiles = []
    }

    private func noteRecent(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentFiles = NSDocumentController.shared.recentDocumentURLs
    }

    func confirmClose(_ document: EditorDocument) -> Bool {
        guard document.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(document)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func confirmCloseAll() -> Bool { documents.allSatisfy { confirmClose($0) } }

    // MARK: Changes made by other apps

    private func watch(_ document: EditorDocument) {
        unwatch(document.id)
        guard let url = document.fileURL else { return }
        let presenter = DocumentFilePresenter(documentID: document.id, url: url)
        let id = document.id
        presenter.onChange = { [weak self] in MainActor.assumeIsolated { self?.noteExternalChange(id) } }
        presenter.onDelete = { [weak self] in MainActor.assumeIsolated { self?.noteExternalChange(id) } }
        presenter.onMove = { [weak self] newURL in MainActor.assumeIsolated { self?.fileMoved(id, to: newURL) } }
        presenters[id] = presenter
        NSFileCoordinator.addFilePresenter(presenter)
        updateFolderWatcher()
    }

    private func unwatch(_ id: UUID) {
        if let presenter = presenters.removeValue(forKey: id) { NSFileCoordinator.removeFilePresenter(presenter) }
        pendingExternalChanges.remove(id)
        updateFolderWatcher()
    }

    /// Watches the open files' folders with FSEvents, so changes made while Tidepad is the active app
    /// (by Claude Code or git in the terminal panel, say) are noticed straight away, not only when
    /// Tidepad is next activated. Most tools don't use file coordination, so the presenters miss them.
    private func updateFolderWatcher() {
        let folders = Set(documents.compactMap { $0.fileURL?.deletingLastPathComponent().resolvingSymlinksInPath().path })
        guard folders != watchedFolders else { return }
        watchedFolders = folders
        folderWatcher = folders.isEmpty ? nil : FolderWatcher(folders: folders.map { URL(fileURLWithPath: $0) }) { [weak self] paths in
            MainActor.assumeIsolated { self?.foldersChanged(paths) }
        }
    }

    private func foldersChanged(_ paths: [String]) {
        // FSEvents reports changes anywhere inside a watched folder; only the open files' folders matter.
        guard paths.contains(where: { watchedFolders.contains($0.hasSuffix("/") ? String($0.dropLast()) : $0) }) else { return }
        for document in documents {
            guard let url = document.fileURL else { continue }
            if FileStamp(url) != document.diskStamp { pendingExternalChanges.insert(document.id) }
        }
        if NSApp?.isActive == true { reviewExternalChanges() }
    }

    private func noteExternalChange(_ id: UUID) {
        // A notification for Tidepad's own write (same date and size as last saved) isn't a change.
        // A deleted file has no stamp, so it always gets through.
        if let document = documents.first(where: { $0.id == id }), let url = document.fileURL,
           !url.pathComponents.contains(".Trash"), FileStamp(url) == document.diskStamp { return }
        pendingExternalChanges.insert(id)
        if NSApp?.isActive == true { reviewExternalChanges() }
    }

    private func fileMoved(_ id: UUID, to url: URL) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        // Moving to the Trash is a deletion as far as the user is concerned.
        if url.pathComponents.contains(".Trash") { noteExternalChange(id); return }
        document.fileURL = url
        document.displayName = url.lastPathComponent
    }

    /// Brings in each file changed or deleted by another app since the last review. A file with no
    /// unsaved edits in Tidepad reloads quietly, as in VS Code (undo brings back the previous text);
    /// Tidepad asks only when both sides changed, or when the file was deleted.
    func reviewExternalChanges() {
        guard !reviewingExternalChanges else { return }
        reviewingExternalChanges = true
        defer { reviewingExternalChanges = false }
        while let id = pendingExternalChanges.popFirst() {
            guard let document = documents.first(where: { $0.id == id }), let url = document.fileURL else { continue }
            if url.pathComponents.contains(".Trash") || !FileManager.default.fileExists(atPath: url.path) {
                askAboutDeletedFile(document)
                continue
            }
            let current = FileStamp(url)
            guard current != document.diskStamp else { continue } // Metadata only, or already seen.
            if !document.hasUnsavedChanges {
                do { try reloadFromDisk(document) } catch { show(error) }
                continue
            }
            selectedID = id
            let alert = NSAlert()
            alert.messageText = "“\(document.displayName)” was changed by another application."
            alert.informativeText = "Reload it from disk? Your unsaved changes in Tidepad will be lost."
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Keep Tidepad’s Version")
            if alert.runModal() == .alertFirstButtonReturn {
                do { try reloadFromDisk(document) } catch { show(error) }
            } else {
                document.diskStamp = current // Don't ask again about this version.
                if !document.hasUnsavedChanges { document.markUnsaved() } // The editor now differs from disk.
            }
        }
    }

    private func askAboutDeletedFile(_ document: EditorDocument) {
        selectedID = document.id
        let alert = NSAlert()
        alert.messageText = "“\(document.displayName)” was deleted or moved to the Trash by another application."
        alert.informativeText = "Keep it open in Tidepad? You can save it again to recreate the file."
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            document.markUnsaved()
        } else if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents.remove(at: index)
            unwatch(document.id)
            if selectedID == document.id { selectedID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id }
        }
    }

    /// Replaces the document's text with the file's current contents, as one undoable step, and
    /// marks it saved. Encoding, BOM and line endings follow the file.
    func reloadFromDisk(_ document: EditorDocument) throws {
        guard let url = document.fileURL else { return }
        var coordinationError: NSError?
        var result: Result<LoadedText, Error>?
        NSFileCoordinator(filePresenter: presenters[document.id]).coordinate(
            readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try files.load(readURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let loaded = try result?.get() else { return }
        document.encoding = loaded.encoding
        document.hasByteOrderMark = loaded.hasBOM
        if document.text != loaded.text { document.text = loaded.text }
        document.markSaved(at: url)
        document.diskStamp = loaded.stamp
        pendingExternalChanges.remove(document.id)
    }
    private func show(_ error: Error) { NSAlert(error: error).runModal() }
}
