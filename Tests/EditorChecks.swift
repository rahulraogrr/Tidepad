import AppKit

@main struct EditorChecks {
    @MainActor static func pump(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let manager = DocumentManager()
        let fixtures = ["sample.txt", "Sample.java", "sample.json", "Sample.swift"]
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = base.appendingPathComponent("build/editor-checks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for filename in fixtures {
            let url = base.appendingPathComponent("Tests/Fixtures/\(filename)")
            manager.open([url])
            guard let document = manager.selectedDocument else { fatalError("Missing document") }
            precondition(document.fileURL == url)
            let original = document.text
            let session = EditorSession(document: document)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 450),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = session.scrollView
            window.makeFirstResponder(session.textView)
            window.contentView?.layoutSubtreeIfNeeded()
            session.textView.layoutManager?.ensureLayout(for: session.textView.textContainer ?? NSTextContainer())
            pump()
            precondition(!document.hasUnsavedChanges, "Coloring must not dirty the document")
            precondition(session.textView.undoManager?.canUndo != true, "Coloring (including bold) must not create undo actions")
            if document.syntaxLanguage != .plain, let storage = session.textView.textStorage {
                var boldFound = false
                storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                    if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) { boldFound = true; stop.pointee = true }
                }
                precondition(boldFound, "Keywords and operators use the real bold font: \(filename)")
                precondition(session.baseFont.fontDescriptor.symbolicTraits.contains(.bold) == false, "The editor's base font stays regular")
            }
            precondition(session.textView.font?.pointSize == 12)
            let length = (original as NSString).length
            let secondLine = (original as NSString).range(of: "\n").location + 1
            session.textView.setSelectedRange(NSRange(location: secondLine, length: 0))
            precondition(document.cursorLine == 2 && document.cursorColumn == 1)
            session.textView.setSelectedRange(NSRange(location: 0, length: 5))
            precondition(document.selectionLength == 5)
            session.textView.setSelectedRange(NSRange(location: length, length: 0))
            session.textView.insertText("\nEdited (42)", replacementRange: session.textView.selectedRange())
            pump()
            precondition(document.text == original + "\nEdited (42)" && document.hasUnsavedChanges)
            precondition(document.selectionLength == 0)
            precondition(document.cursorColumn == 12)
            precondition(session.textView.matchingBrackets.count == 2)
            let attrs = session.textView.layoutManager?.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)
            precondition((attrs?[.foregroundColor] != nil) == (document.syntaxLanguage != .plain), "Unexpected syntax attributes for \(filename)")
            session.textView.undoManager?.undo()
            pump()
            precondition(document.text == original && !document.hasUnsavedChanges, "Undo must restore clean text")
            session.textView.undoManager?.redo()
            pump()
            precondition(document.hasUnsavedChanges)
            let saved = output.appendingPathComponent(filename)
            try TextFileService().write(document, to: saved)
            let reopened = try TextFileService().read(saved)
            precondition(reopened.text == document.text)
            print("PASS open/edit/select/caret/brackets/color/undo/redo/save: \(filename)")

            if filename == "Sample.swift" {
                session.textView.setSelectedRange(NSRange(location: (document.text as NSString).range(of: "{").location + 1, length: 0))
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    pump()
                    session.scrollView.displayIfNeeded()
                    if let bitmap = session.scrollView.bitmapImageRepForCachingDisplay(in: session.scrollView.bounds) {
                        session.scrollView.cacheDisplay(in: session.scrollView.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            try png.write(to: output.appendingPathComponent("editor-\(name).png"))
                        }
                    }
                }
                document.fileURL = output.appendingPathComponent("renamed.txt")
                session.setLanguage(document.syntaxLanguage)
                pump()
                let cleared = session.textView.layoutManager?.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)
                precondition(cleared?[.foregroundColor] == nil, "Changing extension must clear colors")
            }
            window.contentView = nil
        }
        let limited = EditorSession(document: EditorDocument(fileURL: URL(fileURLWithPath: "/limited.swift"), text: "let value = 42"),
                                    syntaxPolicy: SyntaxPolicy(maximumUTF16Length: 5))
        pump()
        precondition(limited.textView.layoutManager?.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)[.foregroundColor] == nil)
        precondition(limited.document.text == "let value = 42")
        checkSearchEditing()
        checkTextCommands()
        try checkExternalChanges(output: output)
        try checkDocumentGroups(output: output)
        try checkScrolling(output: output)
        print("All native AppKit editor checks passed.")
    }
    @MainActor static func checkSearchEditing() {
        let document = EditorDocument(text: "cat cat\n😀 café\nlast\n")
        let session = EditorSession(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.scrollView
        window.makeFirstResponder(session.textView)
        pump()
        let original = document.text
        precondition(session.applySearchReplacement(range: NSRange(location: 0, length: 7), text: "longer longer"))
        pump()
        precondition(document.text.hasPrefix("longer longer") && document.hasUnsavedChanges)
        session.textView.undoManager?.undo(); pump()
        precondition(document.text == original && !document.hasUnsavedChanges, "Replace All one undo")
        session.textView.undoManager?.redo(); pump()
        precondition(document.text.hasPrefix("longer longer"), "Replace All redo")
        for value in ["1", "2", "4"] { precondition(session.goToLine(value), "valid line") }
        precondition(session.textView.selectedRange().location == (document.text as NSString).length, "last empty line")
        for value in ["0", "-1", "5", "abc"] { precondition(!session.goToLine(value), "invalid line") }
        session.revealSearchMatch(NSRange(location: 14, length: 2))
        precondition(document.cursorLine == 2 && document.cursorColumn == 1 && document.selectionLength == 1)
        precondition(document.text.hasPrefix("longer longer"), "Search decoration leaves text unchanged")
        document.markSaved(at: URL(fileURLWithPath: "/tmp/savepoint.txt"))
        let saved = document.text
        session.textView.insertText("a", replacementRange: NSRange(location: 0, length: 0)); pump()
        session.textView.insertText("b", replacementRange: NSRange(location: 1, length: 0)); pump()
        while document.text != saved && session.textView.undoManager?.canUndo == true {
            let beforeUndo = document.text
            session.textView.undoManager?.undo(); pump()
            precondition(document.text != beforeUndo, "Undo must change text, not just the savepoint token")
        }
        precondition(document.text == saved && !document.hasUnsavedChanges, "Undo to saved generation")
        session.textView.undoManager?.redo(); pump()
        precondition(document.hasUnsavedChanges, "Redo away from saved generation")
        window.contentView = nil
        print("PASS search replacement/undo/redo, Unicode selection, Go to Line bounds")
    }

    @MainActor static func checkTextCommands() {
        let document = EditorDocument(text: "b\na\nb\n")
        let session = EditorSession(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.scrollView
        window.makeFirstResponder(session.textView)
        pump()
        let text = session.textView.textStorage!.mutableString
        guard let sort = TextCommands.sortLines(text, selection: NSRange(location: 0, length: 0), ascending: true, lineEnding: "\n") else { fatalError("Sort edit") }
        precondition(session.apply(sort)); pump()
        precondition(document.text == "a\nb\nb\n" && document.hasUnsavedChanges, "Sort applied")
        precondition(session.textView.undoManager?.undoActionName == "Sort Lines Ascending", "Undo is named after the command")
        guard let dedupe = TextCommands.removeDuplicateLines(text, selection: NSRange(location: 0, length: 0), lineEnding: "\n") else { fatalError("Dedupe edit") }
        precondition(session.apply(dedupe)); pump()
        precondition(document.text == "a\nb\n")
        session.textView.setSelectedRange(NSRange(location: 2, length: 0))
        guard let move = TextCommands.moveLines(text, selection: session.textView.selectedRange(), up: true) else { fatalError("Move edit") }
        precondition(session.apply(move)); pump()
        precondition(document.text == "b\na\n" && session.textView.selectedRange().location == 0 && document.cursorLine == 1, "Move keeps the caret on the moved line")
        for _ in 0..<3 { session.textView.undoManager?.undo(); pump() }
        precondition(document.text == "b\na\nb\n" && !document.hasUnsavedChanges, "Each command is one undo step")
        window.contentView = nil
        print("PASS text commands apply as single named undo steps")
    }

    /// Another app's coordinated write is noticed through NSFilePresenter; Tidepad's own saves aren't.
    /// (The app isn't active in this harness, so changes are queued rather than prompting.)
    @MainActor static func checkExternalChanges(output: URL) throws {
        let url = output.appendingPathComponent("external.txt")
        try "one\n".write(to: url, atomically: false, encoding: .utf8)
        let manager = DocumentManager()
        manager.closeAll()
        manager.open([url])
        guard let document = manager.selectedDocument else { fatalError("Missing document") }
        pump(0.5)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { target in
            try? "two\n".write(to: target, atomically: false, encoding: .utf8)
        }
        pump(1.5)
        precondition(manager.pendingExternalChanges.contains(document.id), "A change by another app is noticed")
        try manager.reloadFromDisk(document)
        precondition(document.text == "two\n" && !document.hasUnsavedChanges && manager.pendingExternalChanges.isEmpty, "Reload")
        document.text = "three\n"
        precondition(manager.save(document))
        pump(1.5)
        precondition(manager.pendingExternalChanges.isEmpty, "Tidepad's own save isn't an external change")
        // An uncoordinated write (like `echo >>` in Terminal) is found by the stamp check on activation.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("four\n".utf8)); try handle.close()
        precondition(FileStamp(url) != document.diskStamp, "An uncoordinated append changes the stamp")
        manager.closeAll()
        print("PASS external change detection, reload, own saves ignored")
    }

    @MainActor static func checkDocumentGroups(output: URL) throws {
        let manager = DocumentManager()
        manager.closeAll()
        for index in 1...2 {
            let url = output.appendingPathComponent("save-all-\(index).txt")
            try "original".write(to: url, atomically: true, encoding: .utf8)
            manager.open([url])
            manager.selectedDocument?.text = "edited \(index)"
        }
        let selected = manager.selectedID
        manager.saveAll()
        precondition(manager.selectedID == selected)
        for document in manager.documents {
            guard let url = document.fileURL else { fatalError("Expected saved URL") }
            let text = try String(contentsOf: url, encoding: .utf8)
            precondition(text == document.text && !document.hasUnsavedChanges)
        }
        manager.closeAll(except: selected)
        precondition(manager.documents.count == 1 && manager.selectedID == selected)
        manager.closeAll()
        precondition(manager.documents.isEmpty && manager.selectedID == nil)
        manager.newDocument()
        manager.saveAll() // A blank Untitled tab has nothing to save and must not open a Save panel.
        precondition(manager.documents.count == 1 && manager.selectedDocument?.fileURL == nil)
        print("PASS Save All, Close Other Tabs, and Close All")
    }

    @MainActor static func checkScrolling(output: URL) throws {
        let text = (1...250).map { "let line\($0) = \($0) // scrolling fixture" }.joined(separator: "\n")
        let document = EditorDocument(fileURL: URL(fileURLWithPath: "/scroll.swift"), text: text)
        let session = EditorSession(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.scrollView
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let layout = session.textView.layoutManager, let container = session.textView.textContainer else {
            fatalError("Missing text layout")
        }
        layout.ensureLayout(for: container)
        pump()
        let offset = (text as NSString).range(of: "let line200").location
        session.textView.setSelectedRange(NSRange(location: offset, length: 0))
        let glyph = layout.glyphIndexForCharacter(at: offset)
        let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        session.scrollView.contentView.scroll(to: NSPoint(x: session.scrollView.contentView.bounds.minX, y: lineRect.minY - 50))
        session.scrollView.reflectScrolledClipView(session.scrollView.contentView)
        pump()
        precondition(document.cursorLine == 200 && document.lineCount == 250)
        precondition(session.scrollView.contentView.bounds.minY > 0)
        let point = session.ruler.convert(NSPoint(x: 0, y: lineRect.minY + session.textView.textContainerOrigin.y), from: session.textView)
        precondition(point.y > 0 && point.y < 150, "Gutter coordinates must track vertical scroll")
        let attributes = layout.temporaryAttributes(atCharacterIndex: offset, effectiveRange: nil)
        precondition(attributes[.foregroundColor] != nil, "Scrolling must color newly visible text")
        if let bitmap = session.scrollView.bitmapImageRepForCachingDisplay(in: session.scrollView.bounds) {
            session.scrollView.cacheDisplay(in: session.scrollView.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("editor-scrolled.png"))
            }
        }
        session.textView.setSelectedRange(NSRange(location: 0, length: offset))
        session.textView.insertText("", replacementRange: session.textView.selectedRange())
        pump()
        precondition(document.lineCount == 51 && session.ruler.lineIndex.starts.count == 51)
        precondition(document.cursorLine == 1)
        session.textView.insertText(String(repeating: "x", count: 2_000), replacementRange: NSRange(location: 0, length: 0))
        layout.ensureLayout(for: container)
        pump()
        precondition(session.textView.frame.width > session.scrollView.contentSize.width, "Long lines must scroll horizontally")
        let beforeSettings = document.text
        let wasDirty = document.hasUnsavedChanges
        session.applyDisplayOptions(EditorDisplayOptions(wordWrap: true))
        layout.ensureLayout(for: container)
        pump()
        precondition(container.widthTracksTextView && !session.scrollView.hasHorizontalScroller)
        precondition(layout.usedRect(for: container).width <= session.textView.visibleRect.width + 1, "Wrapped text must fit the visible editor width")
        var options = EditorDisplayOptions()
        options.font.size = 16
        options.font.tabWidth = 8
        options.showLineNumbers = false
        session.applyDisplayOptions(options)
        pump()
        precondition(session.textView.font?.pointSize == 16 && !session.scrollView.rulersVisible)
        precondition(session.textView.defaultParagraphStyle?.defaultTabInterval == EditorFontProvider.paragraphStyle(font: EditorFontProvider.font(configuration: options.font), configuration: options.font).defaultTabInterval)
        precondition(document.text == beforeSettings && document.hasUnsavedChanges == wasDirty)
        print("PASS scrolled syntax/gutter alignment, line deletion, horizontal scrolling, wrapping, font/tab settings, and gutter toggle")
        window.contentView = nil
    }

}
