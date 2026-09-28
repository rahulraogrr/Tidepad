import AppKit

/// Collects a WebSocket's messages (for the Claude Code connection check). URLSession calls back on
/// its own queue, so this isn't tied to the main actor.
final class WebSocketInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: Any]] = []
    private var didFail = false
    var messages: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return stored }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return didFail }

    func listen(to task: URLSessionWebSocketTask) {
        task.receive { [self] result in
            switch result {
            case .success(let message):
                var data = Data()
                if case .string(let text) = message { data = Data(text.utf8) }
                if case .data(let bytes) = message { data = bytes }
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    lock.lock(); stored.append(object); lock.unlock()
                }
                listen(to: task)
            case .failure:
                lock.lock(); didFail = true; lock.unlock()
            }
        }
    }
}

@main struct EditorChecks {
    @MainActor static func pump(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
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
        print("PASS terminal: login shell on a pseudo-terminal, command output, select and copy, working directory, tabs, exit")
    }

    /// The Claude Code connection end to end, with Foundation's WebSocket client in place of Claude Code:
    /// the lock file, the token check, the MCP handshake, tool calls and selection notifications.
    @MainActor static func checkClaudeCodeConnection(output: URL) throws {
        let fm = FileManager.default
        let config = output.appendingPathComponent("claude-config")
        let folder = output.appendingPathComponent("ide-project")
        try? fm.removeItem(at: config)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("App.java")
        try "class App {\n  int x = 1;\n}\n".write(to: file, atomically: true, encoding: .utf8)
        let suite = "TidepadEditorChecksIDE"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Missing defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = DocumentManager()
        manager.closeAll()
        let sessions = EditorSessionStore()
        let project = ProjectFolder(defaults: defaults)
        let claude = ClaudeCodeConnection(manager: manager, sessions: sessions, project: project, server: IDEServer(configDirectory: config))
        sessions.selectionChanged = { claude.selectionChanged(in: $0) }
        project.open(folder)
        claude.start()
        func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { pump(0.05) }
            return condition()
        }
        precondition(wait { claude.server.port != nil }, "The server starts")
        guard let port = claude.server.port, let lockURL = claude.server.lockFile else { fatalError("No port") }
        let lock = try JSONSerialization.jsonObject(with: Data(contentsOf: lockURL)) as? [String: Any] ?? [:]
        precondition(lock["authToken"] as? String == claude.server.token && lock["ideName"] as? String == "Tidepad"
                     && lock["transport"] as? String == "ws" && (lock["pid"] as? Int) == Int(ProcessInfo.processInfo.processIdentifier), "Lock file: \(lock)")
        precondition((lock["workspaceFolders"] as? [String]) == [folder.resolvingSymlinksInPath().path], "The open folder is the workspace")
        let permissions = try fm.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600, "Only the user can read the lock file")
        precondition(claude.server.token.count == 32 && claude.terminalEnvironment["CLAUDE_CODE_SSE_PORT"] == String(port))

        func connect(token: String) -> (URLSessionWebSocketTask, WebSocketInbox) {
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
            request.setValue(token, forHTTPHeaderField: "x-claude-code-ide-authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            let inbox = WebSocketInbox()
            task.resume()
            inbox.listen(to: task)
            return (task, inbox)
        }
        func send(_ task: URLSessionWebSocketTask, _ message: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: message)
            task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
        }

        // A wrong token is refused.
        let (intruder, intruderInbox) = connect(token: String(repeating: "0", count: 32))
        send(intruder, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [String: Any]()])
        let refused = wait(3) { intruderInbox.failed || !intruderInbox.messages.isEmpty }
        _ = refused
        precondition(intruderInbox.messages.isEmpty, "A client without the token gets no answer")
        precondition(claude.connectedClients == 0, "A refused client doesn't count as connected")
        intruder.cancel(with: .normalClosure, reason: nil)

        // The right token: handshake, a tool call, selection notifications.
        let (client, inbox) = connect(token: claude.server.token)
        send(client, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        precondition(wait { inbox.messages.contains { $0["id"] as? Int == 1 } }, "Handshake reply")
        let hello = inbox.messages.first { $0["id"] as? Int == 1 }?["result"] as? [String: Any]
        precondition((hello?["serverInfo"] as? [String: Any])?["name"] as? String == "tidepad", "Server info")
        precondition(wait { claude.connectedClients == 1 }, "The client is connected")
        send(client, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "getWorkspaceFolders", "arguments": [String: Any]()]])
        precondition(wait { inbox.messages.contains { $0["id"] as? Int == 2 } }, "Tool reply")
        let folders = inbox.messages.first { $0["id"] as? Int == 2 }.flatMap { (($0["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String } ?? ""
        precondition(folders.contains(folder.resolvingSymlinksInPath().lastPathComponent), "Workspace folders: \(folders)")
        send(client, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "openFile", "arguments": ["filePath": file.path, "startText": "int x"]]])
        precondition(wait { inbox.messages.contains { $0["id"] as? Int == 3 } } && manager.selectedDocument?.fileURL?.lastPathComponent == "App.java", "openFile")
        guard let document = manager.selectedDocument else { fatalError("No document") }
        let session = sessions.session(for: document)
        pump(0.2)
        precondition(session.textView.selectedRange() == NSRange(location: 14, length: 5), "openFile selects the text: \(session.textView.selectedRange())")
        session.textView.setSelectedRange(NSRange(location: 14, length: 9))
        precondition(wait { inbox.messages.contains { ($0["method"] as? String) == "selection_changed" && (($0["params"] as? [String: Any])?["text"] as? String) == "int x = 1" } },
                     "Selections are sent to Claude Code")
        let change = inbox.messages.last { ($0["method"] as? String) == "selection_changed" }?["params"] as? [String: Any]
        let start = ((change?["selection"] as? [String: Any])?["start"] as? [String: Any])
        precondition(start?["line"] as? Int == 1 && start?["character"] as? Int == 2, "Selection position: \(String(describing: start))")
        client.cancel(with: .normalClosure, reason: nil)
        precondition(wait { claude.connectedClients == 0 }, "Disconnects are noticed (still \(claude.connectedClients))")
        claude.stop()
        precondition(!fm.fileExists(atPath: lockURL.path), "Stopping removes the lock file")
        manager.closeAll()
        print("PASS Claude Code connection: lock file, token check, handshake, tool calls, openFile selection, selection notifications, disconnect")
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
        checkSearchEditing()
        checkTextCommands()
        try checkExternalChanges(output: output)
        try checkDocumentGroups(output: output)
        try checkScrolling(output: output)
        try checkProjectSidebar(output: output)
        checkTerminal(output: output)
        try checkClaudeCodeConnection(output: output)
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
