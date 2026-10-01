import AppKit
import SwiftUI
import Observation

actor CompiledSearchCache {
    private var query: SearchQuery?
    private var engine: SearchEngine?
    func get(_ value: SearchQuery) throws -> SearchEngine {
        if query == value, let engine { return engine }
        let compiled = try SearchEngine(value)
        query = value; engine = compiled
        return compiled
    }
}

@MainActor @Observable final class SearchResultsModel {
    var rows: [SearchResult] = []
    var visible = false
    var collapsed = false
    var summary = ""
    func reset() { rows = []; visible = true; collapsed = false; summary = "Searching…" }
}

@MainActor @Observable final class SearchController {
    enum Tab: String, CaseIterable { case find = "Find", replace = "Replace", files = "Find in Files" }
    var tab: Tab = .find { didSet { panel?.setContentSize(NSSize(width: 640, height: panelHeight)) } }
    var panelHeight: CGFloat { tab == .files ? 280 : (tab == .replace ? 258 : 230) }
    var query = SearchQuery() { didSet { if query != oldValue { validate() } } }
    var replacement = ""
    var directory = ""
    var filters = "*.*"
    var message = ""
    var validationError: String?
    var busy = false
    var filesBusy = false
    var fileCount = 0
    var history = SearchHistory()
    let results = SearchResultsModel()
    @ObservationIgnored weak var context: WorkspaceCommandContext?
    @ObservationIgnored private let cache = CompiledSearchCache()
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var fileTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var fileGeneration = UUID()
    @ObservationIgnored private var resultsGeneration = UUID()
    @ObservationIgnored private var activationGeneration = UUID()
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var linePanel: NSPanel?
    @ObservationIgnored private(set) var progress: Progress?
    @ObservationIgnored private var lastMatch: (UUID, UInt64, NSRange, SearchQuery)?
    /// The large-file view's last match, to step over it when it's empty.
    @ObservationIgnored private var lastLargeMatch: (buffer: LargeTextBuffer, revision: Int, range: Range<Int>)?
    var canSearch: Bool { !query.text.isEmpty && validationError == nil }
    var hasDocument: Bool { context?.hasDocument == true }

    init(context: WorkspaceCommandContext) { self.context = context }

    private func validate() {
        cancelDocumentSearch(); cancelFiles(); fileGeneration = UUID(); filesBusy = false
        validationTask?.cancel(); validationError = nil
        let query = query, cache = cache
        validationTask = Task { [weak self] in
            do { _ = try await cache.get(query) }
            catch { if !Task.isCancelled && self?.query == query { self?.validationError = error.localizedDescription } }
        }
    }
    private func remember() { history.record(find: query.text, replacement: replacement, directory: directory, filter: filters) }
    func show(_ tab: Tab) {
        self.tab = tab
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: panelHeight),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "TidePad Search"; panel.isReleasedWhenClosed = false
            // Stay above Tidepad's window, but hide while another app is active.
            panel.hidesOnDeactivate = true; panel.level = .floating
            panel.contentView = NSHostingView(rootView: SearchPanelView(controller: self))
            panel.center(); self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
    }
    func hide() { panel?.orderOut(nil) }
    var isPanelVisible: Bool { panel?.isVisible == true }
    func chooseDirectory() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.begin { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            self?.directory = url.path
        }
    }
    func cancelDocumentSearch() { generation = UUID(); task?.cancel(); busy = false }
    func cancelFiles() { progress?.cancel(); fileTask?.cancel() }

    func navigate(backwards: Bool = false) {
        if let view = context?.largeView { navigateLarge(view, backwards: backwards); return }
        guard let context, let session = context.session else { return }
        let document = session.document, selection = session.textView.selectedRange()
        let snapshot = SearchSnapshot(text: document.text, revision: document.revision)
        let query = query, cache = cache
        var excluded: NSRange?
        if let last = lastMatch, last.0 == document.id, last.1 == document.revision, last.2 == selection, last.3 == query, selection.length == 0 { excluded = selection }
        let excluding = excluded
        cancelDocumentSearch(); let token = generation; busy = true; remember()
        task = Task { [weak self] in
            do {
                let engine = try await cache.get(query)
                let worker = Task.detached(priority: .userInitiated) {
                    engine.next(snapshot, from: backwards ? selection.location : NSMaxRange(selection), backwards: backwards,
                                excluding: excluding, cancelled: { Task.isCancelled })
                }
                let match = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard let self, self.generation == token else { return }
                defer { self.busy = false }
                guard !Task.isCancelled, document.revision == snapshot.revision, context.document?.id == document.id,
                      session.textView.selectedRange() == selection else { self.message = "Search discarded: document or selection changed."; return }
                if let match {
                    session.revealSearchMatch(match.range)
                    self.lastMatch = (document.id, document.revision, match.range, query)
                    self.message = "Match found."
                } else { self.message = "No match found." }
            } catch { self?.finish(error, token: token) }
        }
    }

    /// Find Next/Previous in the large-file view, in the background on a snapshot so editing can go
    /// on (LargeTextSearch: a byte search for plain text, NSRegularExpression in chunks otherwise).
    private func navigateLarge(_ view: LargeTextView, backwards: Bool) {
        let search: LargeTextSearch
        do { search = try LargeTextSearch(query) } catch { message = error.localizedDescription; return }
        let buffer = view.buffer, snapshot = buffer.snapshot(), selection = view.selectedBytes, wrap = query.wrap
        // An empty match (^, $) where the caret is was just found: step over it.
        var excluding: Range<Int>?
        if let last = lastLargeMatch, last.buffer === buffer, last.revision == buffer.revision, last.range == selection, selection.isEmpty { excluding = selection }
        let excluded = excluding
        cancelDocumentSearch(); let token = generation; busy = true; remember()
        message = "Searching…"
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                search.next(in: snapshot, from: backwards ? selection.lowerBound : selection.upperBound, backwards: backwards,
                            wrap: wrap, excluding: excluded, cancelled: { Task.isCancelled })
            }
            let match = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, self.generation == token else { return }
            self.busy = false
            guard !Task.isCancelled, view.buffer === buffer, buffer.revision == snapshot.revision else {
                self.message = "Search discarded: the document changed."; return
            }
            if let match {
                view.select(match)
                self.lastLargeMatch = (buffer, buffer.revision, match)
                self.message = "Match found."
            } else { self.message = "No match found." }
        }
    }

    /// Count in the large-file view.
    private func countLarge(_ view: LargeTextView) {
        let search: LargeTextSearch
        do { search = try LargeTextSearch(query) } catch { message = error.localizedDescription; return }
        let buffer = view.buffer, snapshot = buffer.snapshot()
        cancelDocumentSearch(); let token = generation; busy = true; remember()
        message = "Counting…"
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { search.count(in: snapshot, cancelled: { Task.isCancelled }) }
            let count = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, self.generation == token else { return }
            self.busy = false
            guard !Task.isCancelled else { return }
            self.message = count == 1 ? "1 match." : "\(count.formatted()) matches."
        }
    }

    /// Replace, Replace All and Replace All in Selection in the large-file view. The matches and their
    /// replacements are worked out in the background on a snapshot; if the document is unchanged, they
    /// go in as one undoable edit (LargeTextView.replace(matches:)), pieces over the file, so nothing
    /// is rewritten. At most 100,000, as in the normal editor.
    private func replaceLarge(_ view: LargeTextView, all: Bool, inSelection: Bool, findNext: Bool) {
        guard view.isEditable else { message = "This file isn't UTF-8, so TidePad shows it read-only."; return }
        let search: LargeTextSearch
        do { search = try LargeTextSearch(query) } catch { message = error.localizedDescription; return }
        let buffer = view.buffer, snapshot = buffer.snapshot(), selection = view.selectedBytes, template = replacement
        if inSelection && selection.isEmpty { message = "Select text to replace within."; return }
        let scope = all && !inSelection ? buffer.contentStart..<buffer.count : selection
        cancelDocumentSearch(); let token = generation; busy = true; remember()
        message = all ? "Replacing…" : ""
        task = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) { () throws -> [LargeTextSearch.Edit]? in
                    if all { return try search.replacements(in: snapshot, range: scope, template: template, cancelled: { Task.isCancelled }) }
                    return try search.replacement(forSelection: selection, in: snapshot, template: template, cancelled: { Task.isCancelled })
                        .map { [(range: selection, bytes: $0)] }
                }
                let edits = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.generation == token else { return }
                self.busy = false
                guard !Task.isCancelled, view.buffer === buffer, buffer.revision == snapshot.revision, view.selectedBytes == selection else {
                    self.message = "Replace cancelled: document or selection changed."; return
                }
                // Like Notepad++, Replace with no matching selection moves to the next match instead.
                guard let edits, let first = edits.first, let last = edits.last else {
                    if all { self.message = "No matches." } else { self.message = "No matching text selected."; self.navigateLarge(view, backwards: false) }
                    return
                }
                let delta = edits.reduce(0) { $0 + $1.bytes.count - $1.range.count }
                let after: Range<Int>
                if inSelection {
                    after = selection.lowerBound..<(selection.upperBound + delta)
                } else if all {
                    // The caret stays where it was, moved by the replacements before it.
                    let caret = selection.lowerBound + edits.lazy.filter { $0.range.upperBound <= selection.lowerBound }.reduce(0) { $0 + $1.bytes.count - $1.range.count }
                    after = caret..<caret
                } else {
                    let end = first.range.lowerBound + first.bytes.count
                    after = end..<end
                }
                guard view.replace(matches: edits, in: first.range.lowerBound..<last.range.upperBound, select: after, action: all ? "Replace All" : "Replace") else {
                    self.message = "Nothing was replaced."; return
                }
                self.message = edits.count == 1 ? "Replaced 1 match." : "Replaced \(edits.count.formatted()) matches."
                self.lastLargeMatch = nil
                if findNext { self.navigateLarge(view, backwards: false) }
            } catch { self?.finish(error, token: token) }
        }
    }

    func findAll(countOnly: Bool = false) {
        if let view = context?.largeView {
            if countOnly { countLarge(view) } else { message = "Find All isn't available for large files yet." }
            return
        }
        guard let context, let session = context.session else { return }
        let document = session.document, snapshot = SearchSnapshot(text: session.document.text, revision: session.document.revision)
        let query = query, cache = cache, id = document.id, name = document.displayName, url = document.fileURL
        cancelDocumentSearch(); let token = generation; busy = true; remember()
        if !countOnly { cancelFiles(); resultsGeneration = token; results.reset() }
        task = Task { [weak self] in
            do {
                let engine = try await cache.get(query)
                let worker = Task.detached(priority: .userInitiated) { () -> ([SearchResult], Int, Bool) in
                    let timing = SearchTiming("Find All"); defer { timing.finish() }
                    var builder = SearchResultBuilder(snapshot), rows: [SearchResult] = [], count = 0, truncated = false
                    engine.enumerate(snapshot, cancelled: { Task.isCancelled }) { range, _ in
                        count += 1
                        if !countOnly {
                            if rows.count == 100_000 { truncated = true; return false }
                            rows.append(builder.result(range, documentID: id, url: url, name: name, revision: snapshot.revision))
                        }
                        return true
                    }
                    return (rows, count, truncated)
                }
                let (rows, count, truncated) = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard let self, self.generation == token else { return }
                defer { self.busy = false }
                guard document.revision == snapshot.revision, context.documents.documents.contains(where: { $0.id == id }), !Task.isCancelled else {
                    self.message = "Search discarded: document changed."; return
                }
                self.message = truncated ? "Showing first 100,000 matches; refine the query." : "\(count) matches."
                if !countOnly && self.resultsGeneration == token {
                    let timer = SearchTiming("Result publication")
                    self.results.rows = rows; self.results.summary = self.message; timer.finish()
                }
            } catch { self?.finish(error, token: token) }
        }
    }

    func replace(all: Bool = false, inSelection: Bool = false, findNext: Bool = false) {
        if let view = context?.largeView { replaceLarge(view, all: all, inSelection: inSelection, findNext: findNext); return }
        guard let context, let session = context.session else { return }
        let document = session.document, snapshot = SearchSnapshot(text: session.document.text, revision: session.document.revision)
        let selection = session.textView.selectedRange()
        if inSelection && selection.length == 0 { message = "Select text to replace within."; return }
        let scope: NSRange? = all && !inSelection ? nil : selection
        let query = query, template = replacement, cache = cache
        cancelDocumentSearch(); let token = generation; busy = true; remember()
        task = Task { [weak self] in
            do {
                let engine = try await cache.get(query)
                let worker = Task.detached(priority: .userInitiated) {
                    try engine.replacement(snapshot, template: template, range: scope, exact: !all, cancelled: { Task.isCancelled })
                }
                let plan = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.generation == token else { return }
                self.busy = false
                guard !Task.isCancelled, document.revision == snapshot.revision, context.document?.id == document.id,
                      session.textView.selectedRange() == selection else { self.message = "Replace cancelled: document or selection changed."; return }
                // Like Notepad++, Replace with no matching selection moves to the next match instead.
                guard let plan else { self.message = "No matching text selected."; if !all { self.navigate() }; return }
                let timer = SearchTiming("Replace commit")
                guard session.applySearchReplacement(range: plan.range, text: plan.text, selection: all ? NSRange(location: selection.location, length: 0) : nil) else { self.message = "Editor rejected replacement."; return }
                if inSelection {
                    session.textView.setSelectedRange(NSRange(location: selection.location, length: selection.length + (plan.text as NSString).length - plan.range.length))
                }
                timer.finish(); self.message = "Replaced \(plan.count) matches."
                self.lastMatch = plan.range.length == 0 ? (document.id, document.revision, session.textView.selectedRange(), query) : nil
                if findNext { self.navigate() }
            } catch { self?.finish(error, token: token) }
        }
    }

    func findInFiles() {
        guard canSearch, !directory.isEmpty else { return }
        cancelFiles(); cancelDocumentSearch(); let token = UUID(); fileGeneration = token; resultsGeneration = token
        let progress = Progress(totalUnitCount: -1); self.progress = progress
        progress.isCancellable = true; filesBusy = true; fileCount = 0; results.reset(); remember()
        let directory = URL(fileURLWithPath: directory), filters = filters, query = query, cache = cache
        fileTask = Task { [weak self] in
            do {
                let engine = try await cache.get(query)
                guard let owner = self else { return }
                let worker = Task.detached(priority: .utility) {
                    await FindInFilesService().run(directory: directory, filters: filters, engine: engine, progress: progress) { update in
                        await owner.publish(update, token: token)
                    }
                }
                await withTaskCancellationHandler { await worker.value } onCancel: { progress.cancel(); worker.cancel() }
                guard let self, self.fileGeneration == token else { return }
                self.filesBusy = false
                if self.resultsGeneration == token {
                    self.results.summary += progress.isCancelled ? " — Cancelled" : " — Complete"
                }
            } catch {
                guard let self, self.fileGeneration == token else { return }
                self.message = error.localizedDescription; self.filesBusy = false
            }
        }
    }
    private func publish(_ update: FileSearchUpdate, token: UUID) {
        guard fileGeneration == token, resultsGeneration == token else { return }
        let timer = SearchTiming("File result publication"); defer { timer.finish() }
        results.rows.append(contentsOf: update.results); fileCount = update.files
        if let error = update.error { results.summary = error; message = error; return }
        results.summary = "\(update.matches) matches · \(update.files) files · \(update.skipped) skipped"
        if update.truncated { results.summary += " · 100,000 result limit" }
    }
    private func finish(_ error: Error, token: UUID) {
        guard generation == token else { return }; busy = false
        if !(error is CancellationError) { message = error.localizedDescription }
    }

    func activate(_ result: SearchResult) {
        guard let context else { return }
        let activation = UUID(); activationGeneration = activation
        if let id = result.documentID {
            guard let document = context.documents.documents.first(where: { $0.id == id }), document.revision == result.revision else {
                message = "This result is stale. Search again."; results.summary = message; return
            }
            context.documents.selectedID = id
        } else if let url = result.url {
            let expectedSelection = context.documents.selectedID
            Task { [weak self] in
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) {
                        let before = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                        guard before.contentModificationDate == result.fileDate, before.fileSize == result.fileSize else { throw CocoaError(.fileReadUnknown) }
                        let document = try TextFileService().load(url)
                        let after = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                        guard after.contentModificationDate == before.contentModificationDate, after.fileSize == before.fileSize else { throw CocoaError(.fileReadUnknown) }
                        return document
                    }.value
                    guard let self, self.activationGeneration == activation, context.documents.selectedID == expectedSelection else { return }
                    if let open = context.documents.documents.first(where: { $0.fileURL == url }) {
                        guard !open.hasUnsavedChanges, open.text == loaded.text else {
                            self.message = "The open document differs from the searched file. Search again."; self.results.summary = self.message; return
                        }
                        context.documents.selectedID = open.id
                    } else {
                        context.documents.acceptOpened(loaded.makeDocument())
                    }
                    self.reveal(result, context: context)
                } catch { self?.message = "Cannot activate result: file changed or is unreadable. Search again." }
            }
            return
        }
        reveal(result, context: context)
    }
    private func reveal(_ result: SearchResult, context: WorkspaceCommandContext) {
        guard let session = context.session else { return }
        session.revealSearchMatch(result.range)
        context.window?.makeKeyAndOrderFront(nil); context.window?.makeFirstResponder(session.textView)
    }

    func showGoToLine() {
        guard let context, let document = context.document else { return }
        // The text view's Go to Line, or the large-file view's.
        let target: (String) -> Bool, focus: NSView
        if let view = context.largeView {
            target = { input in Int(input.trimmingCharacters(in: .whitespacesAndNewlines)).map { view.goToLine($0) } ?? false }
            focus = view
        } else if let session = context.session {
            target = { session.goToLine($0) }
            focus = session.textView
        } else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 135), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Go to Line"; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: GoToLineView(document: document, go: { [weak self, weak panel] input in
            guard self?.context?.document?.id == document.id else { return false }
            guard target(input) else { return false }
            panel?.close(); self?.context?.window?.makeKeyAndOrderFront(nil)
            self?.context?.window?.makeFirstResponder(focus); return true
        }, cancel: { [weak panel] in panel?.close() }))
        linePanel?.close(); linePanel = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
    }
}
