import AppKit
import Observation

@MainActor @Observable final class DocumentManager {
    var documents: [EditorDocument] = []
    var selectedID: UUID?
    var recentFiles: [URL] = NSDocumentController.shared.recentDocumentURLs
    private let files = TextFileService()
    private var untitledCount = 0
    var selectedDocument: EditorDocument? { documents.first { $0.id == selectedID } }

    init() { newDocument() }

    func newDocument() {
        untitledCount += 1
        let document = EditorDocument(displayName: untitledCount == 1 ? "Untitled" : "Untitled \(untitledCount)")
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
                noteRecent(url)
            } catch { show(error) }
        }
    }

    func acceptOpened(_ document: EditorDocument) {
        if let url = document.fileURL, let existing = documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            selectedID = existing.id; return
        }
        documents.append(document); selectedID = document.id
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
        do {
            try files.write(document, to: destination)
            document.markSaved(at: destination)
            noteRecent(destination)
            return true
        } catch {
            show(error)
            return false
        }
    }

    func close(_ document: EditorDocument) {
        guard confirmClose(document), let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        if selectedID == document.id {
            selectedID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
        }
    }

    func saveAll() {
        let original = selectedID
        for document in documents where document.hasUnsavedChanges || document.fileURL == nil {
            selectedID = document.id
            guard save(document) else { return }
        }
        selectedID = original
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
    private func show(_ error: Error) { NSAlert(error: error).runModal() }
}
