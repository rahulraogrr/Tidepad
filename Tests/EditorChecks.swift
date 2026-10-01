import AppKit

@main struct EditorChecks {
    @MainActor static func pump(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// A file over the threshold opens in the large-file view: mapped, not read into a String; lines,
    /// Go to Line, keyboard moves, selection, Copy and the status bar work; editing stays off.
    @MainActor static func checkLargeFile(output: URL) throws {
        let url = output.appendingPathComponent("large.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let block = Data((0..<10_000).map { "2026-09-30 12:00:00 INFO request \($0) café 中文 status=200\n" }.joined().utf8)
        var written = 0
        while written <= LargeTextFile.threshold { handle.write(block); written += block.count }
        try handle.close()
        let started = Date()
        guard case .large(let file) = try TextFileService().open(url) else { fatalError("A large file must open in the large-file view") }
        let openTime = Date().timeIntervalSince(started) * 1000
        let document = OpenedFile.large(file).makeDocument()
        guard let buffer = document.largeBuffer else { fatalError("No buffer") }
        precondition(document.isLarge && document.text.isEmpty && document.lineCount == file.lineCount, "Large document")
        let view = LargeTextView(document: document, buffer: buffer, options: EditorDisplayOptions())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view.scrollView
        view.pasteboard = NSPasteboard(name: NSPasteboard.Name("TidepadLargeChecks"))
        window.makeFirstResponder(view)
        window.displayIfNeeded()
        precondition(view.goToLine(12_346) && document.cursorLine == 12_346 && document.cursorColumn == 1, "Go to Line")
        precondition(!view.goToLine(0) && !view.goToLine(buffer.lineCount + 1), "Go to Line bounds")
        view.moveToEndOfLine(nil)
        let line = buffer.lineRange(12_345)
        precondition(view.selectedBytes == line.upperBound..<line.upperBound && document.cursorColumn == buffer.characterCount(in: line) + 1, "End of line")
        view.moveToBeginningOfLineAndModifySelection(nil)
        view.copy(nil)
        precondition(view.pasteboard.string(forType: .string) == "2026-09-30 12:00:00 INFO request 2345 café 中文 status=200", "Select and copy: \(view.pasteboard.string(forType: .string) ?? "")")
        view.moveDown(nil)
        precondition(document.cursorLine == 12_347, "Move down")
        view.moveToEndOfDocument(nil)
        precondition(document.cursorLine == buffer.lineCount && view.selectedBytes == buffer.count..<buffer.count, "End of document")
        window.displayIfNeeded()
        let match = buffer.find(Array("request 9999 café".utf8), from: 0)!
        view.select(match)
        precondition(document.cursorLine == 10_000 && view.selectedBytes == match, "Reveal a match")
        view.setLanguage(.sql) // Colours: drawn with the lexer's tokens, then back to plain text.
        window.displayIfNeeded()
        view.setLanguage(.plain)

        // Editing: typing (one undo step), Return, delete, paste, undo back to saved, redo, save.
        let lines = buffer.lineCount, size = buffer.count
        let start = buffer.lineStart(5)
        view.select(start..<start)
        let typeStarted = Date()
        for character in "Tidepad " { view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let typingTime = Date().timeIntervalSince(typeStarted) * 1000 / 8
        precondition(buffer.text(in: buffer.lineRange(5)).hasPrefix("Tidepad 2026-09-30") && document.hasUnsavedChanges, "Typing")
        pump(0.01) // Undo groups close at the end of each event, as when typing by hand.
        view.moveLeft(nil); view.moveRight(nil) // Moving the caret ends the typing step.
        view.insertNewline(nil)
        pump(0.01)
        precondition(buffer.lineCount == lines + 1 && document.cursorLine == 7 && document.cursorColumn == 1, "Return")
        view.deleteBackward(nil)
        pump(0.01)
        precondition(buffer.lineCount == lines && buffer.text(in: buffer.lineRange(5)).hasPrefix("Tidepad 2026"), "Delete")
        view.pasteboard.clearContents()
        view.pasteboard.setString("pasted\nlines\n", forType: .string)
        view.paste(nil)
        pump(0.01)
        precondition(buffer.lineCount == lines + 2 && buffer.text(in: buffer.lineRange(6)) == "lines", "Paste")
        let undo = view.undoManager!
        undo.undo() // the paste
        precondition(buffer.lineCount == lines, "Undo paste")
        undo.undo() // Delete
        undo.undo() // Return
        undo.undo() // the typing, as one step
        precondition(buffer.count == size && buffer.text(in: buffer.lineRange(5)).hasPrefix("2026-09-30") && !document.hasUnsavedChanges,
                     "Undo back to the saved text clears the unsaved state")
        undo.redo()
        pump(0.01)
        precondition(buffer.text(in: buffer.lineRange(5)).hasPrefix("Tidepad 2026") && document.hasUnsavedChanges, "Redo")
        // Input method composition: marked text shown in place, committed as one undo step.
        view.setMarkedText("ｔ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(view.hasMarkedText() && view.markedRange().length == 1, "Marked text")
        view.setMarkedText("テ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("テ", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(!view.hasMarkedText() && buffer.text(in: buffer.lineRange(5)).hasPrefix("Tidepad テ2026"), "Committed composition")
        pump(0.01)
        undo.undo()
        precondition(buffer.text(in: buffer.lineRange(5)).hasPrefix("Tidepad 2026"), "Undo composition")
        // A composition interrupted by Paste (or a click, Undo, a search match) is accepted as it is first.
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.pasteboard.clearContents()
        view.pasteboard.setString("P", forType: .string)
        view.paste(nil)
        precondition(!view.hasMarkedText() && buffer.text(in: buffer.lineRange(5)).hasPrefix("Tidepad かP2026"), "Paste commits the composition first")
        pump(0.01)
        undo.undo()
        pump(0.01)
        if !buffer.text(in: buffer.lineRange(5)).hasPrefix("Tidepad 2026") { undo.undo() }
        precondition(buffer.text(in: buffer.lineRange(5)).hasPrefix("Tidepad 2026"), "Undo the paste and the composition")
        // A file that isn't UTF-8 (here Latin-1) is read-only: typing, pasting and replacing leave it alone.
        func smallView(_ name: String, _ bytes: [UInt8]) throws -> (LargeTextView, EditorDocument, NSWindow) {
            let url = output.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            let document = OpenedFile.large(try LargeTextFile(url: url)).makeDocument()
            let small = LargeTextView(document: document, buffer: document.largeBuffer!, options: EditorDisplayOptions())
            let holder = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            holder.contentView = small.scrollView
            holder.makeFirstResponder(small)
            small.pasteboard = view.pasteboard
            return (small, document, holder)
        }
        let latinBytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x0A, 0x78] // "café", "x" in Latin-1
        let (latin, latinDocument, latinWindow) = try smallView("latin1-large.txt", latinBytes)
        latin.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        latin.paste(nil)
        latin.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let latinReplaced = latin.replace(matches: [(range: 0..<1, bytes: [0x41])], in: 0..<1, select: 0..<0, action: "Replace")
        precondition(!latin.isEditable && !latinReplaced && latinDocument.largeBuffer?.bytes(in: 0..<6) == latinBytes
                     && !latinDocument.hasUnsavedChanges && !latin.hasMarkedText(), "A file that isn't UTF-8 is read-only")
        precondition(latinDocument.largeBuffer?.text(in: 0..<6) == "caf\u{FFFD}\nx", "Its other bytes are shown as U+FFFD")
        latinWindow.contentView = nil
        // Pasted text takes the file's line breaks, so a CR file's line index stays right.
        let (crView, crDocument, crWindow) = try smallView("cr-large.txt", Array("one\rtwo".utf8))
        view.pasteboard.clearContents()
        view.pasteboard.setString("a\nb\r\nc\r", forType: .string)
        crView.select(3..<3)
        crView.paste(nil)
        guard let crBuffer = crDocument.largeBuffer else { fatalError("No buffer") }
        precondition(crBuffer.bytes(in: 0..<crBuffer.count) == Array("onea\rb\rc\r\rtwo".utf8) && crBuffer.lineCount == 5,
                     "Pasted line breaks become the file's: \(crBuffer.text(in: 0..<crBuffer.count).debugDescription)")
        crWindow.contentView = nil
        // Replace All with a regular expression: one undoable edit over pieces of the file.
        let size2 = buffer.count
        let replaceStarted = Date()
        let edits = try LargeTextSearch(SearchQuery(text: "status=(\\d+)$", mode: .regex))
            .replacements(in: buffer, range: buffer.contentStart..<buffer.lineStart(1_000), template: "STATUS=$1")
        view.replace(matches: edits, in: edits.first!.range.lowerBound..<edits.last!.range.upperBound, select: 0..<0, action: "Replace All")
        let replaceTime = Date().timeIntervalSince(replaceStarted) * 1000
        precondition(edits.count == 1_000 && buffer.count == size2 && buffer.text(in: buffer.lineRange(999)).hasSuffix("STATUS=200")
                     && buffer.text(in: buffer.lineRange(1_000)).hasSuffix(" status=200") && undo.undoMenuItemTitle == "Undo Replace All", "Replace All")
        pump(0.01)
        undo.undo()
        precondition(buffer.text(in: buffer.lineRange(999)).hasSuffix(" status=200") && buffer.text(in: buffer.lineRange(5)).hasPrefix("Tidepad 2026"), "Undo Replace All")
        // Save: streamed, then the buffer starts again from the saved file; undo still works after.
        let saveStarted = Date()
        try TextFileService().write(document, to: url)
        let saveTime = Date().timeIntervalSince(saveStarted) * 1000
        let saved = try Data(contentsOf: url)
        precondition(saved.count == buffer.count && String(decoding: saved.prefix(buffer.lineStart(6)), as: UTF8.self).components(separatedBy: "\n")[5].hasPrefix("Tidepad 2026"), "Saved")
        buffer.rebase(on: try LargeTextFile(url: url))
        document.markSaved(at: url)
        document.diskStamp = FileStamp(url)
        precondition(buffer.pieces.count == 1 && !document.hasUnsavedChanges, "Re-based after saving")
        undo.undo()
        precondition(buffer.text(in: buffer.lineRange(5)).hasPrefix("2026-09-30") && document.hasUnsavedChanges, "Undo after saving")
        // Quitting keeps the unsaved edits as a journal (not the file), replayed at the next launch.
        pump(0.01)
        view.select(buffer.lineStart(7)..<buffer.lineStart(7))
        view.insertText("KEPT ", replacementRange: NSRange(location: NSNotFound, length: 0))
        let expected = buffer.bytes(in: 0..<buffer.count)
        let sessionDirectory = output.appendingPathComponent("large-session")
        try? FileManager.default.removeItem(at: sessionDirectory)
        let manager = DocumentManager()
        manager.documents = [document]
        manager.selectedID = document.id
        precondition(SessionKeeper(manager: manager, sessions: EditorSessionStore(), terminal: TerminalPanel(), directory: sessionDirectory).save(),
                     "Unsaved large-file edits are kept")
        let journalSize = try FileManager.default.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.contains(".journal") && !$0.lastPathComponent.hasSuffix("-base") } // The kept clone takes no space.
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        precondition(journalSize > 0 && journalSize < 100_000, "The journal holds the edits, not the file: \(journalSize) bytes")
        let relaunched = DocumentManager()
        SessionKeeper(manager: relaunched, sessions: EditorSessionStore(), terminal: TerminalPanel(), directory: sessionDirectory).restore()
        guard let restored = relaunched.documents.first, let restoredBuffer = restored.largeBuffer else { fatalError("The large tab comes back") }
        precondition(restored.hasUnsavedChanges && restoredBuffer.bytes(in: 0..<restoredBuffer.count) == expected
                     && restoredBuffer.text(in: restoredBuffer.lineRange(7)).hasPrefix("KEPT 2026"), "Edits come back, still unsaved")
        // Another app rewrites the start of the file (same size), and "Keep TidePad's Version" is chosen.
        // The edits must come back over the version they were made against, never over the new bytes.
        let rewrite = try FileHandle(forWritingTo: url)
        try rewrite.write(contentsOf: Data("CHANGED BY ANOTHER APP".utf8)); try rewrite.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        restored.diskStamp = FileStamp(url) // What Keep TidePad's Version does.
        precondition(SessionKeeper(manager: relaunched, sessions: EditorSessionStore(), terminal: TerminalPanel(), directory: sessionDirectory).save())
        let keptCopy = try FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path).contains { $0.hasSuffix(".journal-base") }
        precondition(keptCopy == restoredBuffer.file.isCloned, "The version the edits were made against is kept (as a clone)")
        let third = DocumentManager()
        var told: [String] = []
        let thirdKeeper = SessionKeeper(manager: third, sessions: EditorSessionStore(), terminal: TerminalPanel(), directory: sessionDirectory)
        thirdKeeper.tell = { message, _ in told.append(message) }
        thirdKeeper.restore()
        if keptCopy {
            guard let again = third.documents.first, let againBuffer = again.largeBuffer else { fatalError("The large tab comes back again") }
            precondition(againBuffer.bytes(in: 0..<againBuffer.count) == expected && again.hasUnsavedChanges && told.isEmpty
                         && again.diskStamp == FileStamp(url) && again.fileURL == url,
                         "TidePad's version comes back over the bytes it was made against")
        } else {
            precondition(told.count == 1 && third.documents.first?.largeBuffer?.bytes(in: 0..<22) == Array("CHANGED BY ANOTHER APP".utf8),
                         "Without a clone, the file opens as it is and TidePad says the edits couldn't be restored")
        }
        window.displayIfNeeded()
        window.contentView = nil
        print(String(format: "PASS large file: %d MB opened in %.0f ms (%@), %d lines, Go to Line, selection, Copy, typing (%.2f ms a key), Return, delete, paste, input methods, Replace All of 1,000 (regex) in %.1f ms, undo/redo, save in %.0f ms, unsaved edits kept across launches",
                     file.count >> 20, openTime, file.isCloned ? "APFS clone" : "read into memory", file.lineCount, typingTime, replaceTime, saveTime))
        try? FileManager.default.removeItem(at: url)
    }

    /// Return types the document's line break, so a Windows (CRLF) file stays CRLF, and a document
    /// without line breaks keeps the line ending chosen for it.
    @MainActor static func checkLineEndings() {
        let windows = EditorSession(document: EditorDocument(text: "one\r\ntwo"))
        windows.textView.setSelectedRange(NSRange(location: 3, length: 0))
        windows.textView.insertNewline(nil)
        precondition(windows.document.text == "one\r\n\r\ntwo" && windows.document.lineEnding == .crlf, "Return in a CRLF file: \(windows.document.text.debugDescription)")
        let unix = EditorSession(document: EditorDocument(text: "a\nb"))
        unix.textView.setSelectedRange(NSRange(location: 1, length: 0))
        unix.textView.insertNewline(nil)
        precondition(unix.document.text == "a\n\nb", "Return in an LF file")
        let blank = EditorSession(document: EditorDocument(text: ""))
        blank.document.lineEnding = .crlf
        blank.updateLineEnding()
        blank.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        precondition(blank.document.lineEnding == .crlf, "A document without line breaks keeps its chosen line ending")
        blank.textView.insertNewline(nil)
        precondition(blank.document.text == "x\r\n", "Return types the chosen line ending: \(blank.document.text.debugDescription)")
        print("PASS line endings: Return types the document's line break; a chosen line ending is kept")
    }

    /// Printing: the whole text in the editor font, black on white, with the Light theme's syntax colours
    /// and bold keywords, however far the editor has coloured it on screen.
    @MainActor static func checkPrinting() {
        let source = "let answer = 42 // the answer\n" + String(repeating: "print(answer)\n", count: 2_000) + "return \"done\""
        let index = LineIndex()
        index.rebuild(source)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = DocumentPrinter.printableText(source as NSString, index: index, language: .swift, font: font, paragraph: .default)
        precondition(text.string == source, "Printing keeps the text")
        func colour(at offset: Int) -> NSColor? { text.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor }
        func isBold(at offset: Int) -> Bool {
            (text.attribute(.font, at: offset, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        }
        let keyword = SyntaxPalette.color(for: .keyword, language: .swift, dark: false)
        precondition(colour(at: 0) == keyword && isBold(at: 0), "Keywords print in the Light theme's colour, bold")
        precondition(colour(at: 4) == .black && !isBold(at: 4), "Plain text prints black")
        let last = (source as NSString).range(of: "return", options: .backwards).location
        precondition(colour(at: last) == keyword, "The end of a long document is coloured too")
        let plain = DocumentPrinter.printableText(source as NSString, index: index, language: .plain, font: font, paragraph: .default)
        precondition(plain.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .black, "Plain text files print black")
        print("PASS printing: whole document, editor font, Light theme syntax colours and bold keywords")
    }

    /// JSON keys and values, links (URLs and email addresses) and colouring past the old 1 MB limit.
    @MainActor static func checkLinksAndLargeFiles() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let text = "{\n  \"site\": \"https://example.com/docs\",\n  \"mail\": \"team@example.com\"\n}\n"
        let session = EditorSession(document: EditorDocument(fileURL: URL(fileURLWithPath: "/links.json"), text: text))
        window.contentView = session.scrollView
        window.contentView?.layoutSubtreeIfNeeded()
        pump()
        guard let layout = session.textView.layoutManager, let linkAt = session.textView.linkAt else { fatalError("Missing layout or links") }
        let source = text as NSString
        let url = source.range(of: "https://example.com/docs"), mail = source.range(of: "team@example.com")
        let key = source.range(of: "site")
        precondition(linkAt(url.location + 3) == URL(string: "https://example.com/docs"), "URLs are links")
        precondition(linkAt(mail.location)?.scheme == "mailto", "Email addresses are links")
        precondition(linkAt(key.location) == nil, "Other text isn't a link")
        precondition(layout.temporaryAttributes(atCharacterIndex: url.location, effectiveRange: nil)[.underlineStyle] != nil, "Links are underlined")
        let keyColor = layout.temporaryAttributes(atCharacterIndex: key.location, effectiveRange: nil)[.foregroundColor] as? NSColor
        let valueColor = layout.temporaryAttributes(atCharacterIndex: url.location, effectiveRange: nil)[.foregroundColor] as? NSColor
        precondition(keyColor != nil && valueColor != nil && keyColor != valueColor, "JSON keys and values have different colours")
        session.textView.insertText("\n", replacementRange: NSRange(location: 0, length: 0))
        pump()
        precondition(linkAt(url.location + 4) == URL(string: "https://example.com/docs"), "Links follow edits")

        // A 3 MB file is coloured at the top and at the end.
        let record = "{\"key\": \"value\", \"n\": 42},\n"
        let large = EditorSession(document: EditorDocument(fileURL: URL(fileURLWithPath: "/large.json"),
                                                           text: String(repeating: record, count: 110_000)))
        window.contentView = large.scrollView
        window.contentView?.layoutSubtreeIfNeeded()
        pump()
        guard let largeLayout = large.textView.layoutManager else { fatalError("Missing layout") }
        precondition(largeLayout.temporaryAttributes(atCharacterIndex: 1, effectiveRange: nil)[.foregroundColor] != nil, "Large files are coloured")
        precondition(large.goToLine("110000"))
        pump()
        let lastLine = large.index.starts[109_999]
        precondition(largeLayout.temporaryAttributes(atCharacterIndex: lastLine + 1, effectiveRange: nil)[.foregroundColor] != nil,
                     "The end of a large file is coloured")
        window.contentView = nil
        print("PASS JSON key/value colours, links (URL, email, underline, after edits), colouring a 3 MB file")
    }

    /// The project sidebar: opening a folder, the tree, ignored items, revealing the open file and
    /// files created outside Tidepad appearing on their own.
    @MainActor static func checkProjectSidebar(output: URL) throws {
        let fm = FileManager.default
        let root = output.appendingPathComponent("project")
        try? fm.removeItem(at: root)
        for folder in ["src/main/java/app", "target/classes", ".git"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["pom.xml", "README.md", "src/main/java/app/App.java", "debug.log"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
        try "*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let suite = "TidepadEditorChecks"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Missing defaults") }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = ProjectFolder(defaults: defaults)
        var opened: [URL] = []
        let tree = FileTreeController(project: project, openFile: { opened.append($0) })
        let outline = tree.outlineView
        func names() -> [String] { (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.name } }
        project.open(root)
        tree.update(selectedFile: nil)
        precondition(names() == ["src", ".gitignore", "pom.xml", "README.md"], "Top level hides .git, target and ignored files: \(names())")
        // The file being edited is revealed: its folders expand and it's selected, without opening anything.
        let app = root.appendingPathComponent("src/main/java/app/App.java")
        tree.update(selectedFile: app)
        precondition((outline.item(atRow: outline.selectedRow) as? FileNode)?.name == "App.java", "The open file is selected")
        precondition(names().starts(with: ["src", "main", "java", "app", "App.java"]), "Its folders expand: \(names())")
        precondition(opened.isEmpty)
        project.showIgnored = true
        tree.update(selectedFile: app)
        precondition(names().contains(".git") && names().contains("target") && names().contains("debug.log"), "Show ignored files: \(names())")
        project.showIgnored = false
        tree.update(selectedFile: app)
        // Files created by other programs appear without a refresh (FSEvents).
        try Data().write(to: root.appendingPathComponent("NOTES.md"))
        try Data().write(to: root.appendingPathComponent("src/main/java/app/Service.java"))
        let deadline = Date().addingTimeInterval(5)
        while !(names().contains("NOTES.md") && names().contains("Service.java")) && Date() < deadline { pump(0.1) }
        precondition(names().contains("NOTES.md") && names().contains("Service.java"), "New files appear: \(names())")
        precondition(names().starts(with: ["src", "main", "java", "app"]), "Expanded folders stay expanded: \(names())")
        // Recent folders are remembered.
        precondition(ProjectFolder(defaults: defaults).recentFolders.first?.path == root.resolvingSymlinksInPath().path, "Recent folders")
        project.close()
        tree.update(selectedFile: nil)
        precondition(outline.numberOfRows == 0, "Closing the folder empties the tree")
        print("PASS project sidebar: folder tree, ignored files, revealing the open file, live updates, recent folders")
    }

    /// The terminal panel: a real login shell on a pseudo-terminal, a command and its output, the
    /// working directory, and the shell exiting.
    @MainActor static func checkTerminal(output: URL) {
        let terminal = TerminalPanel()
        terminal.workingDirectory = { output }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = terminal.view
        terminal.show()
        precondition(terminal.isRunning && terminal.isVisible, "The shell starts when the panel is shown")
        precondition(terminal.screen.columns > 80, "The grid fits the view: \(terminal.screen.columns) columns")
        func allText() -> String {
            let screen = terminal.screen
            let back = (0..<screen.scrollback.count).map { screen.text(ofRow: $0, scrolledBack: screen.scrollback.count) }
            return (back + (0..<screen.rows).map { screen.text(ofRow: $0) }).joined(separator: "\n")
        }
        func wait(until condition: () -> Bool, seconds: TimeInterval = 15) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { pump(0.1) }
            return condition()
        }
        terminal.view.send?(Array("echo tidepad-$((6*7))\r".utf8))
        precondition(wait { allText().contains("tidepad-42") }, "A command runs and its output shows:\n\(allText())")
        // Select All and Copy, into a private pasteboard so the user's clipboard is untouched.
        terminal.view.pasteboard = NSPasteboard(name: NSPasteboard.Name("TidepadEditorChecks"))
        terminal.view.selectAll(nil)
        terminal.view.copy(nil)
        precondition(terminal.view.pasteboard.string(forType: .string)?.contains("tidepad-42") == true, "Select All and Copy")
        terminal.view.clearSelection()
        // VoiceOver sees a text area with the visible lines, and the cursor as the insertion point.
        let view = terminal.view
        let value = view.accessibilityValue() as? String ?? ""
        precondition(view.isAccessibilityElement() && view.accessibilityRole() == .textArea && value.contains("tidepad-42"),
                     "VoiceOver reads the terminal:\n\(value)")
        precondition(view.accessibilityLabel()?.hasPrefix("Terminal") == true && view.accessibilityNumberOfCharacters() == (value as NSString).length)
        let outputLine = value.components(separatedBy: "\n").firstIndex { $0.hasSuffix("tidepad-42") } ?? -1
        let lineRange = view.accessibilityRange(forLine: outputLine)
        precondition(view.accessibilityString(for: lineRange)?.hasPrefix("tidepad-42") == true
                     && view.accessibilityLine(for: lineRange.location) == outputLine, "Lines for VoiceOver")
        let caret = view.accessibilitySelectedTextRange()
        precondition(caret.length == 0 && view.accessibilityInsertionPointLineNumber() == terminal.screen.cursorRow, "The cursor is the insertion point")
        let frame = view.accessibilityFrame(for: lineRange)
        precondition(frame.width > 0 && frame.height > 0 && NSEqualRanges(view.accessibilityRange(for: NSPoint(x: frame.minX + 1, y: frame.midY)),
                                                                         NSRange(location: lineRange.location, length: 1)),
                     "Frames and points: \(frame), \(view.accessibilityRange(for: NSPoint(x: frame.minX + 1, y: frame.midY))) for \(lineRange)")
        terminal.view.send?(Array("pwd\r".utf8))
        let path = output.resolvingSymlinksInPath().path
        precondition(wait { allText().components(separatedBy: "\n").contains { $0.hasSuffix(path) } }, "The shell starts in the folder:\n\(allText())")
        // A second terminal in its own tab, separate from the first, then closing it.
        let first = terminal.selected
        terminal.newTerminal()
        guard let second = terminal.selected, let first, second !== first else { fatalError("No second terminal") }
        precondition(terminal.sessions.count == 2 && second.isRunning && second.number == 2, "A second terminal")
        func text(_ session: TerminalSession) -> String {
            (0..<session.screen.rows).map { session.screen.text(ofRow: $0) }.joined(separator: "\n")
        }
        second.view.send?(Array("echo second-$((2*21))\r".utf8))
        precondition(wait { text(second).contains("second-42") }, "The second terminal runs commands:\n\(text(second))")
        precondition(!text(first).contains("second-42"), "Terminals are separate")
        terminal.close(second)
        precondition(terminal.sessions.count == 1 && terminal.selected === first && terminal.isVisible && !second.isRunning,
                     "Closing a tab ends its shell and selects another")
        terminal.view.send?(Array("exit\r".utf8))
        precondition(wait { !terminal.isRunning }, "The shell exits")
        terminal.close(first)
        precondition(terminal.sessions.isEmpty && !terminal.isVisible, "Closing the last tab hides the panel")
        window.contentView = nil
        print("PASS terminal: login shell on a pseudo-terminal, command output, select and copy, VoiceOver, working directory, tabs, exit")
    }

    /// The session and settings survive a relaunch: unsaved and Untitled text, the tabs and the selected
    /// tab, file stamps (no false "changed by another application"), backups, and every setting.
    @MainActor static func checkSessionAndPreferences(output: URL) throws {
        let fm = FileManager.default
        let directory = output.appendingPathComponent("session")
        try? fm.removeItem(at: directory)
        let edited = output.appendingPathComponent("session-edited.txt"), clean = output.appendingPathComponent("session-clean.txt")
        try "on disk\n".write(to: edited, atomically: true, encoding: .utf8)
        try "clean\n".write(to: clean, atomically: true, encoding: .utf8)
        let manager = DocumentManager() // Starts with a blank Untitled tab, which isn't worth keeping.
        manager.open([edited, clean])
        guard let editedDocument = manager.documents.first(where: { $0.fileURL?.lastPathComponent == "session-edited.txt" }) else { fatalError("Missing tab") }
        editedDocument.text = "edited but not saved\n"
        manager.newDocument()
        manager.selectedDocument?.text = "scratch notes\n"
        manager.selectedID = editedDocument.id
        let keeper = SessionKeeper(manager: manager, sessions: EditorSessionStore(), terminal: TerminalPanel(), directory: directory)
        precondition(keeper.save(), "The session is saved")
        let backups = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".txt") }
        precondition(backups.count == 2, "Backups of the two unsaved tabs: \(backups)")

        // Tidepad starts again.
        let relaunched = DocumentManager()
        let restoredKeeper = SessionKeeper(manager: relaunched, sessions: EditorSessionStore(), terminal: TerminalPanel(), directory: directory)
        restoredKeeper.restore()
        let tabs = relaunched.documents
        precondition(tabs.count == 3, "The tabs come back, without the blank Untitled one: \(tabs.map(\.displayName))")
        precondition(tabs[0].fileURL?.lastPathComponent == "session-edited.txt" && tabs[0].text == "edited but not saved\n" && tabs[0].hasUnsavedChanges,
                     "Unsaved edits come back, still unsaved")
        precondition(relaunched.selectedID == tabs[0].id, "The selected tab comes back")
        precondition(tabs[1].text == "clean\n" && !tabs[1].hasUnsavedChanges, "Saved files reopen from disk")
        precondition(tabs[2].fileURL == nil && tabs[2].text == "scratch notes\n" && tabs[2].hasUnsavedChanges, "Untitled text comes back")
        precondition(FileStamp(edited) == tabs[0].diskStamp, "The file's stamp is kept, so it isn't reported as changed by another app")
        // Saving a restored tab writes the file and drops its backup.
        precondition(relaunched.save(tabs[0]) && restoredKeeper.save())
        let remaining = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".txt") }
        precondition(remaining.count == 1, "A saved tab's backup is removed: \(remaining)")
        let written = try String(contentsOf: edited, encoding: .utf8)
        precondition(written == "edited but not saved\n", "The restored tab saves to its file")

        // A session file TidePad can't read: the folder is kept aside with its backups, never cleaned up.
        for old in try fm.contentsOfDirectory(atPath: output.path) where old.hasPrefix("Session (not restored") {
            try fm.removeItem(at: output.appendingPathComponent(old))
        }
        let damaged = output.appendingPathComponent("Session")
        try? fm.removeItem(at: damaged)
        try fm.createDirectory(at: damaged, withIntermediateDirectories: true)
        try "{ not a session".write(to: damaged.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        try "precious\n".write(to: damaged.appendingPathComponent("\(UUID().uuidString).txt"), atomically: true, encoding: .utf8)
        let damagedKeeper = SessionKeeper(manager: DocumentManager(), sessions: EditorSessionStore(), terminal: TerminalPanel(), directory: damaged)
        var told: [String] = []
        damagedKeeper.tell = { message, _ in told.append(message) }
        damagedKeeper.restore()
        precondition(damagedKeeper.save(), "A new session starts")
        let aside = try fm.contentsOfDirectory(atPath: output.path).filter { $0.hasPrefix("Session (not restored") }
        precondition(told.count == 1 && aside.count == 1, "TidePad says so, and keeps the old session aside: \(told) \(aside)")
        let asideFiles = try fm.contentsOfDirectory(atPath: output.appendingPathComponent(aside[0]).path)
        precondition(asideFiles.contains("session.json") && asideFiles.contains { $0.hasSuffix(".txt") }, "The backups are kept: \(asideFiles)")
        try fm.removeItem(at: output.appendingPathComponent(aside[0]))
        // Sessions written by other versions (keys missing or added) still open.
        try fm.removeItem(at: damaged)
        try fm.createDirectory(at: damaged, withIntermediateDirectories: true)
        let oldSession = #"{"tabs":[{"path":"\#(clean.path)","later":true}],"selected":0,"somethingNew":1}"#
        try oldSession.write(to: damaged.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        let older = DocumentManager()
        let olderKeeper = SessionKeeper(manager: older, sessions: EditorSessionStore(), terminal: TerminalPanel(), directory: damaged)
        olderKeeper.tell = { message, _ in told.append(message) }
        olderKeeper.restore()
        precondition(told.count == 1 && older.documents.contains { $0.fileURL?.lastPathComponent == "session-clean.txt" && $0.text == "clean\n" },
                     "A session with missing and unknown keys is read")
        // Backups are only cleaned up once the session that no longer lists them is written.
        try fm.removeItem(at: damaged)
        try fm.createDirectory(at: damaged.appendingPathComponent("session.json"), withIntermediateDirectories: true) // Can't be written.
        let orphan = damaged.appendingPathComponent("\(UUID().uuidString).txt")
        try "unlisted\n".write(to: orphan, atomically: true, encoding: .utf8)
        precondition(!SessionKeeper(manager: DocumentManager(), sessions: EditorSessionStore(), terminal: TerminalPanel(), directory: damaged).save()
                     && fm.fileExists(atPath: orphan.path), "A failed save cleans nothing up")
        try fm.removeItem(at: damaged)

        // Settings are remembered.
        let suite = "TidepadEditorChecksPreferences"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Missing defaults") }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EditorPreferences(defaults: defaults)
        preferences.fontSize = 15
        preferences.wordWrap = true
        preferences.appearance = .dark
        preferences.tabSize = 2
        preferences.fontName = "Menlo"
        preferences.showToolbar = false
        let reloaded = EditorPreferences(defaults: defaults)
        precondition(reloaded.fontSize == 15 && reloaded.wordWrap && reloaded.appearance == .dark && reloaded.tabSize == 2
                     && reloaded.fontName == "Menlo" && !reloaded.showToolbar && reloaded.showStatusBar, "Settings are remembered")
        preferences.fontName = nil
        precondition(EditorPreferences(defaults: defaults).fontName == nil, "A cleared setting stays cleared")
        print("PASS session: unsaved and Untitled text, tabs, selected tab, file stamps and backups kept across launches; settings remembered")
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
        checkLinksAndLargeFiles()
        checkPrinting()
        checkLineEndings()
        try checkLargeFile(output: output)
        checkSearchEditing()
        checkUndo()
        checkTextCommands()
        try checkExternalChanges(output: output)
        try checkDocumentGroups(output: output)
        try checkScrolling(output: output)
        try checkProjectSidebar(output: output)
        checkTerminal(output: output)
        try checkSessionAndPreferences(output: output)
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
    /// Each tab has its own undo history, and typing undoes as one step (NSTextView's coalescing), with
    /// the saved state followed across Undo and Redo.
    @MainActor static func checkUndo() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let first = EditorSession(document: EditorDocument(text: "alpha\n")), second = EditorSession(document: EditorDocument(text: "beta\n"))
        window.contentView = first.scrollView
        window.makeFirstResponder(first.textView)
        first.textView.setSelectedRange(NSRange(location: 5, length: 0))
        for character in " one two" {
            first.textView.insertText(String(character), replacementRange: first.textView.selectedRange())
            pump(0.01)
        }
        precondition(first.document.text == "alpha one two\n" && first.document.hasUnsavedChanges, "Typed")
        window.contentView = second.scrollView
        window.makeFirstResponder(second.textView)
        precondition(first.textView.undoManager !== second.textView.undoManager && second.textView.undoManager?.canUndo == false,
                     "Each tab has its own undo")
        second.textView.undo(nil)
        precondition(first.document.text == "alpha one two\n" && second.document.text == "beta\n", "Undo in another tab leaves this one alone")
        window.contentView = first.scrollView
        window.makeFirstResponder(first.textView)
        let undoItem = NSMenuItem(title: "Undo", action: #selector(CodeTextView.undo(_:)), keyEquivalent: "")
        precondition(first.textView.validateUserInterfaceItem(undoItem) && undoItem.title == "Undo Typing", "Edit ▸ Undo names this tab's step: \(undoItem.title)")
        first.textView.undo(nil)
        pump(0.01)
        precondition(first.document.text == "alpha\n" && !first.document.hasUnsavedChanges,
                     "Typing undoes in one step, back to the saved text: \(first.document.text.debugDescription)")
        first.textView.redo(nil)
        pump(0.01)
        precondition(first.document.text == "alpha one two\n" && first.document.hasUnsavedChanges, "Redo")
        // Saving, then undoing past the save and redoing back to it.
        first.document.markSaved(at: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("undo-check.txt"))
        precondition(!first.document.hasUnsavedChanges)
        first.textView.undo(nil)
        pump(0.01)
        precondition(first.document.text == "alpha\n" && first.document.hasUnsavedChanges, "Undo past a save")
        first.textView.redo(nil)
        pump(0.01)
        precondition(!first.document.hasUnsavedChanges, "Redo back to the save")
        // Text of the same length that isn't the saved text is still unsaved.
        first.textView.setSelectedRange(NSRange(location: 6, length: 3))
        first.textView.insertText("ONE", replacementRange: first.textView.selectedRange())
        pump(0.01)
        precondition(first.document.text == "alpha ONE two\n" && first.document.hasUnsavedChanges, "Same length, different text")
        first.textView.undo(nil)
        pump(0.01)
        precondition(!first.document.hasUnsavedChanges, "Undo back to the save")
        first.textView.redo(nil)
        pump(0.01)
        precondition(first.document.hasUnsavedChanges, "Redo to text of the saved length that isn't the saved text")
        window.contentView = nil
        print("PASS undo per tab, typing as one undo step, saved state across undo and redo")
    }

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
        // With no unsaved edits in Tidepad, a changed file reloads quietly, without asking.
        manager.checkOpenFilesOnDisk()
        precondition(document.text == "three\nfour\n" && !document.hasUnsavedChanges && manager.pendingExternalChanges.isEmpty, "Quiet reload")

        // Saving over a change no one announced asks first, rather than overwriting it.
        var asked: [(message: String, buttons: [String])] = []
        var answer = NSApplication.ModalResponse.alertFirstButtonReturn
        manager.ask = { alert in asked.append((alert.messageText, alert.buttons.map(\.title))); return answer }
        document.text = "mine\n"
        let unannounced = try FileHandle(forWritingTo: url)
        try unannounced.seekToEnd(); try unannounced.write(contentsOf: Data("five\n".utf8)); try unannounced.close()
        func onDisk() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "(missing)" }
        answer = .alertFirstButtonReturn // Cancel
        precondition(!manager.save(document) && asked.count == 1 && asked[0].buttons == ["Cancel", "Save As…", "Save Anyway"]
                     && onDisk() == "three\nfour\nfive\n" && document.hasUnsavedChanges,
                     "Save asks before overwriting another app's change: \(asked)")
        answer = .alertThirdButtonReturn // Save Anyway
        precondition(manager.save(document) && asked.count == 2 && onDisk() == "mine\n"
                     && !document.hasUnsavedChanges, "Save Anyway")
        document.text = "again\n"
        precondition(manager.save(document) && asked.count == 2, "No question when nothing changed on disk")

        // A deleted file with unsaved edits: Keep Open keeps them, and it isn't asked about again.
        document.text = "unsaved\n"
        try FileManager.default.removeItem(at: url)
        answer = .alertFirstButtonReturn // Keep Open
        manager.checkOpenFilesOnDisk()
        precondition(asked.count == 3 && asked[2].buttons == ["Keep Open", "Save As…", "Close and Discard Changes"]
                     && manager.documents.contains { $0.id == document.id } && document.text == "unsaved\n" && document.hasUnsavedChanges,
                     "Keep Open: \(asked)")
        manager.checkOpenFilesOnDisk()
        precondition(asked.count == 3, "A deleted file is asked about once")
        precondition(manager.save(document) && onDisk() == "unsaved\n" && asked.count == 3,
                     "Saving recreates the file")
        // Closing a deleted tab discards its edits only when that's what the button says.
        let gone = output.appendingPathComponent("gone.txt")
        try "gone\n".write(to: gone, atomically: false, encoding: .utf8)
        manager.open([gone])
        guard let goneDocument = manager.selectedDocument, goneDocument.fileURL == gone else { fatalError("Missing tab") }
        goneDocument.text = "edited\n"
        try FileManager.default.removeItem(at: gone)
        answer = .alertThirdButtonReturn
        manager.checkOpenFilesOnDisk()
        precondition(asked.count == 4 && asked[3].buttons.last == "Close and Discard Changes" && !manager.documents.contains { $0.id == goneDocument.id },
                     "Close and Discard Changes")
        manager.closeAll()
        print("PASS external change detection, reload, own saves ignored, unannounced changes before saving, deleted files")
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
        // New tabs take the first free Untitled name, so closed tabs' numbers are reused.
        let names = DocumentManager()
        names.newDocument(); names.newDocument()
        precondition(names.documents.map(\.displayName) == ["Untitled", "Untitled 2", "Untitled 3"], "Untitled names: \(names.documents.map(\.displayName))")
        names.documents.removeAll { $0.displayName == "Untitled 2" }
        names.newDocument()
        precondition(names.documents.last?.displayName == "Untitled 2", "A closed tab's number is reused")
        precondition(manager.documents.count == 1 && manager.selectedDocument?.fileURL == nil)
        print("PASS Save All, Close Other Tabs, Close All, and Untitled names")
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
        // Compare with line 200's position now: applying syntax fonts to newly visible text makes TextKit
        // re-estimate line positions above it, and NSTextView moves the scroll origin by the same amount
        // so the visible text stays put. The gutter must follow the current geometry.
        let lineRectNow = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil)
        let point = session.ruler.convert(NSPoint(x: 0, y: lineRectNow.minY + session.textView.textContainerOrigin.y), from: session.textView)
        precondition(point.y > 0 && point.y < 150, """
            Gutter coordinates must track vertical scroll: point.y \(point.y), line 200 minY \(lineRectNow.minY), \
            clip minY \(session.scrollView.contentView.bounds.minY)
            """)
        let visibleOffset = lineRectNow.minY - session.scrollView.contentView.bounds.minY
        precondition(abs(visibleOffset - 50) < 1, "The visible text must not jump when syntax fonts apply: \(visibleOffset)")
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
