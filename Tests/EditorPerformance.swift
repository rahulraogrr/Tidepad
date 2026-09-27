import AppKit

@main struct EditorPerformance {
    @MainActor static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now; let result = try work()
        let duration = start.duration(to: .now).components
        print("EDITOR \(name): \(String(format: "%.3f", Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)) ms")
        return result
    }
    @MainActor static func pump() {
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TidepadEditorBench-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = "2026-09-26 INFO request=1234 needle processed successfully payload=abcdefghijklmnopqrstuvwxyz0123456789\n"
        let engine = try SearchEngine(SearchQuery(text: "needle"))
        for size in CommandLine.arguments.dropFirst().compactMap(Int.init).isEmpty ? [100_000, 1_000_000, 10_000_000, 50_000_000] : CommandLine.arguments.dropFirst().compactMap(Int.init) {
            let url = root.appendingPathComponent("fixture.log")
            try String(repeating: line, count: size / line.utf8.count).write(to: url, atomically: true, encoding: .utf8)
            let doc = try measure("\(size) file read") { try TextFileService().read(url) }
            let session = measure("\(size) session create") { EditorSession(document: doc) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = session.scrollView; window.makeFirstResponder(session.textView); measure("\(size) first layout + 150ms runloop settling") { pump() }
            print("LAYOUT allowsNonContiguousLayout=\(session.textView.layoutManager?.allowsNonContiguousLayout ?? false)")
            let second = EditorSession(document: EditorDocument(text: "second tab"))
            for phase in ["idle", "background files"] {
                let progress = Progress(totalUnitCount: -1)
                let started = DispatchSemaphore(value: 0)
                let worker: Task<Void, Never>? = phase == "background files" ? Task.detached {
                    started.signal()
                    while !progress.isCancelled && !Task.isCancelled {
                        await FindInFilesService().run(directory: root, filters: "*.log", engine: engine, progress: progress) { _ in }
                    }
                } : nil
                if worker != nil { started.wait() }
                measure("\(size) \(phase) typing") {
                    session.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
                }
                measure("\(size) \(phase) cursor 100 moves") {
                    for index in 0..<100 { session.textView.setSelectedRange(NSRange(location: index, length: 0)) }
                }
                measure("\(size) \(phase) selection") { session.textView.setSelectedRange(NSRange(location: 10, length: 50)) }
                measure("\(size) \(phase) scroll 20 viewports") {
                    for index in 0..<20 {
                        session.scrollView.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index * 200)))
                        session.scrollView.reflectScrolledClipView(session.scrollView.contentView)
                        session.scrollView.layoutSubtreeIfNeeded(); session.scrollView.displayIfNeeded()
                    }
                }
                measure("\(size) \(phase) tab switch pair") {
                    window.contentView = second.scrollView; window.contentView = session.scrollView
                    window.makeFirstResponder(session.textView)
                }
                progress.cancel(); worker?.cancel(); pump()
            }
            for (name, value) in [("Unicode", "😀"), ("newline", "\n"), ("small paste", "hello\nworld"), ("large paste", String(repeating: line, count: 1000))] {
                measure("\(size) \(name)") { session.textView.insertText(value, replacementRange: NSRange(location: 0, length: 0)) }
            }
            measure("\(size) delete") { session.textView.insertText("", replacementRange: NSRange(location: 0, length: 1)) }
            session.textView.setSelectedRange(NSRange(location: 1, length: 0))
            measure("\(size) backspace") { session.textView.deleteBackward(nil) }
            measure("\(size) undo") { session.textView.undoManager?.undo() }
            measure("\(size) redo") { session.textView.undoManager?.redo() }
            measure("\(size) select all metrics") { session.textView.selectAll(nil) }
            let snapshot = measure("\(size) search snapshot") { SearchSnapshot(text: doc.text, revision: doc.revision) }
            if let plan = try measure("\(size) replace planning", { try SearchEngine(SearchQuery(text: String(repeating: line, count: 10))).replacement(snapshot, template: "replacement") }) {
                measure("\(size) replace NSTextView commit") { _ = session.applySearchReplacement(range: plan.range, text: plan.text, selection: NSRange(location: 0, length: 0)) }
                measure("\(size) replace undo") { session.textView.undoManager?.undo() }
            }
            window.contentView = nil
        }
    }
}
