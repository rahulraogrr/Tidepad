#if DEBUG
import AppKit

@MainActor enum SearchValidation {
    private static var scheduled = false
    private static var report: [String] = []
    private static func check(_ condition: Bool, _ name: String) { report.append("\(condition ? "PASS" : "FAIL"): \(name)") }
    static func schedule(window: NSWindow, context: WorkspaceCommandContext) {
        guard !scheduled, let path = ProcessInfo.processInfo.environment["TIDEPAD_SEARCH_VALIDATE"] else { return }
        scheduled = true
        Task {
            let output = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try? await Task.sleep(for: .milliseconds(500))
            context.documents.newDocument()
            guard let session = context.session else { return }
            let document = session.document, search = context.search
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(session.textView)
            session.textView.insertText("cat CAT scatter cat\n😀 café\nlast\n", replacementRange: NSRange(location: 0, length: 0))
            document.markSaved(at: output.appendingPathComponent("sample.txt"))
            search.query = SearchQuery(text: "cat", wholeWord: true)
            check(key("f", window: window), "Cmd+F routes")
            await pause()
            check(search.isPanelVisible && search.tab == .find, "Non-modal Find panel")
            capture(title: "Tidepad Search", to: output.appendingPathComponent("find-panel.png"))
            check(key("h", window: window), "Cmd+H routes")
            await pause(); check(search.tab == .replace, "Replace tab")
            check(key("f", modifiers: [.command, .shift], window: window), "Cmd+Shift+F binding and menu action")
            await pause(); check(search.tab == .files, "Find in Files tab")
            search.hide(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(session.textView)
            session.textView.setSelectedRange(NSRange(location: 0, length: 0))
            check(key("g", window: window), "Cmd+G routes"); await idle(search)
            check(session.textView.selectedRange() == NSRange(location: 0, length: 3), "Find first")
            check(key("g", window: window), "Cmd+G repeat routes"); await idle(search)
            check(session.textView.selectedRange() == NSRange(location: 4, length: 3), "Case-insensitive next")
            check(key("g", modifiers: [.command, .shift], window: window), "Cmd+Shift+G binding and menu action"); await idle(search)
            check(session.textView.selectedRange().location == 0, "Previous")
            search.replacement = "dog"; search.replace(findNext: true); await idle(search)
            check(document.text.hasPrefix("dog CAT") && session.textView.selectedRange().location == 4, "Replace and find next")
            search.replace(all: true); await idle(search)
            check(document.text.hasPrefix("dog dog scatter dog"), "Replace All")
            session.textView.undoManager?.undo(); await pause()
            check(document.text.hasPrefix("dog CAT scatter cat"), "One Undo restores Replace All: \(document.text.debugDescription)")
            session.textView.undoManager?.redo(); await pause()
            check(document.text.hasPrefix("dog dog scatter dog"), "Redo Replace All")
            search.query = SearchQuery(text: "dog", matchCase: true)
            search.replacement = "fox"
            session.textView.setSelectedRange(NSRange(location: 0, length: 7))
            search.replace(all: true, inSelection: true); await idle(search)
            check(document.text.hasPrefix("fox fox scatter dog") && session.textView.selectedRange() == NSRange(location: 0, length: 7), "Replace All in Selection: \(document.text.debugDescription) message=\(search.message) query=\(search.query.text) selection=\(session.textView.selectedRange())")
            let before = document.text
            search.query = SearchQuery(text: "[", mode: .regex); await pause()
            check(!search.canSearch && search.validationError != nil && document.text == before, "Invalid regex leaves editor untouched")
            search.query = SearchQuery(text: "fox", matchCase: true); search.findAll(); await idle(search)
            check(search.results.rows.count == 2 && search.results.rows.first?.line == 1, "Find All results")
            if let last = search.results.rows.last { search.activate(last); check(session.textView.selectedRange() == last.range, "Result activation") }
            search.replacement = "stale"; search.replace(all: true)
            session.textView.insertText("!", replacementRange: NSRange(location: 0, length: 0))
            await idle(search); check(!document.text.contains("stale"), "Stale replacement rejected")
            if let row = search.results.rows.first { search.activate(row); check(search.message.contains("stale"), "Stale result rejected") }
            check(key("l", window: window), "Cmd+L routes"); await pause()
            check(NSApp.windows.contains { $0.title == "Go to Line" && $0.isVisible }, "Go to Line panel")
            NSApp.windows.first { $0.title == "Go to Line" }?.close()
            let folder = output.appendingPathComponent("files")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? "fox\nfox 😀".write(to: folder.appendingPathComponent("fixture.java"), atomically: true, encoding: .utf8)
            search.directory = folder.path; search.filters = "*.java"; search.findInFiles()
            await filesIdle(search)
            check(search.results.rows.count == 2 && search.fileCount == 1, "Controller recursive file results")
            if let row = search.results.rows.last { search.activate(row); await pause(); check(context.document?.fileURL == row.url && context.session?.textView.selectedRange() == row.range, "File result opens and selects") }
            search.show(.files); await pause()
            capture(title: "Tidepad Search", to: output.appendingPathComponent("files-panel.png"))
            search.hide(); window.makeKeyAndOrderFront(nil); await pause()
            capture(view: window.contentView, to: output.appendingPathComponent("results-panel.png"))
            // Keep test documents clean so normal quit never discards user work or leaves prompts.
            for doc in context.documents.documents { if doc.fileURL != nil { _ = context.documents.save(doc) } }
            let header = "App: \(Bundle.main.bundleURL.path)\nPID: \(ProcessInfo.processInfo.processIdentifier)\n"
            try? (header + report.joined(separator: "\n")).write(to: output.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        }
    }
    private static func pause() async { try? await Task.sleep(for: .milliseconds(150)) }
    private static func idle(_ search: SearchController) async {
        for _ in 0..<400 { await pause(); if !search.busy { return } }
        check(false, "Document operation timeout")
    }
    private static func filesIdle(_ search: SearchController) async {
        for _ in 0..<400 { await pause(); if !search.filesBusy { return } }
        check(false, "File operation timeout")
    }
    private static func key(_ text: String, modifiers: NSEvent.ModifierFlags = .command, window: NSWindow) -> Bool {
        if modifiers.contains(.shift) {
            // Synthetic NSEvents do not reproduce keyboard-layout translation for shifted keys.
            // Verify the native binding and dispatch that menu item; physical-key QA is separate.
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Search" })?.submenu else { return false }
            menu.delegate?.menuNeedsUpdate?(menu); menu.delegate?.menuWillOpen?(menu); menu.update()
            guard let entry = menu.items.first(where: { $0.keyEquivalent == text && $0.keyEquivalentModifierMask == modifiers }) else { return false }
            menu.performActionForItem(at: menu.index(of: entry)); menu.delegate?.menuDidClose?(menu); return true
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: modifiers.contains(.shift) ? text.uppercased() : text, charactersIgnoringModifiers: modifiers.contains(.shift) ? text.uppercased() : text, isARepeat: false, keyCode: ["f": UInt16(3), "g": 5, "h": 4, "l": 37][text] ?? 0) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
    private static func capture(title: String, to url: URL) { capture(view: NSApp.windows.first { $0.title == title }?.contentView, to: url) }
    private static func capture(view: NSView?, to url: URL) {
        guard let view else { return }; view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}
#endif
