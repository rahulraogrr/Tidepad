#if DEBUG
import AppKit

/// Opt-in integration checks against this running Debug app's actual native menus.
@MainActor enum MenuValidation {
    private static var scheduled = false
    private static var results: [String] = []
    private static var panelObserver: ((NSWindow) -> Void)?

    static func presenting(_ window: NSWindow) { panelObserver?(window) }

    static func schedule(window: NSWindow, context: WorkspaceCommandContext) {
        guard !scheduled, let directory = ProcessInfo.processInfo.environment["TIDEPAD_MENU_VALIDATE"] else { return }
        scheduled = true
        Task {
            await settle()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NativeMenuCoordinator.arrange()
            let output = URL(fileURLWithPath: directory)
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try dump().write(to: output.appendingPathComponent("menus-before.txt"), atomically: true, encoding: .utf8)
                let expected = ["TidePad", "File", "Edit", "Search", "View", "Encoding", "Language", "Settings", "Tools", "Window", "Help"]
                check(NSApp.mainMenu?.items.map(\.title) == expected, "Top-level menu order: \(NSApp.mainMenu?.items.map(\.title) ?? [])")
                check(item("About TidePad", menu: "TidePad") != nil && item("Check for Updates…", menu: "TidePad") != nil, "About TidePad and Check for Updates")
                check(CheckEnvironment.isActive && CheckEnvironment.defaults !== UserDefaults.standard, "Checks use their own settings and session")
                check(item("Minimize", menu: "Window") != nil && item("Zoom", menu: "Window") != nil && item("Bring All to Front", menu: "Window") != nil, "Native Window commands retained")
                let count = context.documents.documents.count
                check(key("n", window: window), "Cmd+N routed")
                await settle()
                check(context.documents.documents.count == count + 1, "Cmd+N creates document")
                check(key("w", window: window), "Cmd+W routed")
                await settle()
                check(context.documents.documents.count == count && window.isVisible, "Cmd+W closes tab, not window")
                await verifyModal(key: "o", window: window, expected: "open")
                await settle()
                window.makeKeyAndOrderFront(nil)
                await settle()
                let url = output.appendingPathComponent("menu-check.txt")
                try "Menu check\n".write(to: url, atomically: true, encoding: .utf8)
                context.documents.open([url])
                await settle()
                guard let document = context.document, let session = context.session else { throw CocoaError(.fileReadUnknown) }
                window.makeFirstResponder(session.textView)
                session.textView.insertText("edited", replacementRange: NSRange(location: 0, length: 0))
                await settle()
                check(key("s", window: window), "Cmd+S routed")
                await settle()
                check(!document.hasUnsavedChanges && (try? String(contentsOf: url, encoding: .utf8)) == document.text, "Cmd+S saves current document")
                check(key("f", window: window), "Cmd+F routed")
                await settle()
                check(context.search.isPanelVisible && context.search.tab == .find, "Tidepad Find panel opened")
                check(key("h", window: window), "Cmd+H routed to Replace")
                await settle()
                check(context.search.isPanelVisible && context.search.tab == .replace, "Tidepad Replace panel opened")
                context.search.hide()
                window.makeKeyAndOrderFront(nil)
                check(!NSApp.isHidden, "Cmd+H does not hide application")
                check(allItems().filter { $0.keyEquivalent == "h" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command }.count == 1, "Only Replace owns Cmd+H")
                // Cmd+, opens the Settings window; Cmd+W then closes it, not a tab.
                let tabs = context.documents.documents.count
                check(key(",", window: window), "Cmd+, routed")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await settle()
                let settings = NSApp.windows.first { $0.isVisible && $0 !== window && !($0 is NSPanel) }
                check(settings != nil, "Cmd+, opens the Settings window")
                if let settings {
                    settings.makeKeyAndOrderFront(nil)
                    await settle()
                    check(key("w", window: settings), "Cmd+W routed in Settings")
                    await settle()
                    check(!settings.isVisible && context.documents.documents.count == tabs, "Cmd+W closes Settings, not a tab")
                }
                window.makeKeyAndOrderFront(nil)
                await settle()
                click("Swift", menu: "Language")
                await settle()
                check(document.languageOverride == .swift && item("Swift", menu: "Language")?.state == .on, "Manual language override and checkmark")
                click("Use File Extension", menu: "Language")
                await settle()
                check(document.languageOverride == nil && item("None (Normal Text)", menu: "Language")?.state == .on, "Restore detected language/checkmark")
                for (title, keyPath) in [("Show Toolbar", \EditorPreferences.showToolbar), ("Show Status Bar", \EditorPreferences.showStatusBar), ("Show Line Numbers", \EditorPreferences.showLineNumbers), ("Word Wrap", \EditorPreferences.wordWrap)] {
                    let original = context.preferences[keyPath: keyPath]
                    click(title, menu: "View")
                    await settle()
                    check(context.preferences[keyPath: keyPath] != original && item(title, menu: "View")?.state == (original ? .off : .on), "Toggle and checkmark: \(title)")
                    if title == "Word Wrap" { check(session.textView.textContainer?.widthTracksTextView == true, "Word Wrap applied to NSTextView") }
                    click(title, menu: "View")
                    await settle()
                }
                click("Zoom In", menu: "View")
                await settle()
                check(session.textView.font?.pointSize == 13, "Zoom In applied")
                click("Zoom Out", menu: "View")
                await settle()
                check(session.textView.font?.pointSize == 12, "Zoom Out applied")
                click("Reset Zoom", menu: "View")
                await settle()
                check(session.textView.font?.pointSize == 12, "Reset Zoom applied")
                check(item("UTF-8", menu: "Encoding")?.state == .on, "Encoding checkmark")
                check(item("Reopen with Encoding", menu: "Encoding") != nil && item("Unix (LF)", menu: "Encoding")?.state == .on, "Reopen with Encoding and Line Endings")
                check(!document.hasUnsavedChanges, "Display commands do not dirty text")
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(session.textView)
                await settle()
                auditSystemCommands()
                if let entry = allItems().first(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }) {
                    // Tidepad's item uses ⌃⌘F; recent macOS versions supply their own (fn/🌐-F) instead.
                    check(entry.target == nil && entry.keyEquivalent.lowercased() == "f", "Native Full Screen target and shortcut")
                    check(NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: entry), "Native Full Screen action routed")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    check(window.styleMask.contains(.fullScreen), "Native Full Screen enters full screen")
                    if window.styleMask.contains(.fullScreen) {
                        NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: entry)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        check(!window.styleMask.contains(.fullScreen), "Native Full Screen exits full screen")
                    }
                }

                try dump().write(to: output.appendingPathComponent("menus-after.txt"), atomically: true, encoding: .utf8)
            } catch { results.append("FAIL: \(error)") }
            let report = "App: \(Bundle.main.bundleURL.path)\nPID: \(ProcessInfo.processInfo.processIdentifier)\n" + results.joined(separator: "\n")
            try? report.write(to: output.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        }
    }

    private static func auditSystemCommands() {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
            menu.delegate?.menuDidClose?(menu)
        }
        let actions = ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:",
                       "toggleFullScreen:", "performMiniaturize:", "performZoom:", "terminate:"]
        for action in actions {
            let matches = allItems().filter { $0.action.map(NSStringFromSelector) == action }
            check(matches.count == 1, "Exactly one native \(action) (found \(matches.count))")
        }
        let fullScreen = allItems().filter { $0.title == "Enter Full Screen" || $0.title == "Exit Full Screen" }
        check(fullScreen.count == 1 && fullScreen.first?.action == #selector(NSWindow.toggleFullScreen(_:)),
              "Full Screen uses only the native responder-chain action")
        check(allItems().filter { $0.title == "About TidePad" }.count == 1, "Exactly one About TidePad")
    }

    private static func settle() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
        NSApp.mainMenu?.items.forEach {
            if let menu = $0.submenu { menu.delegate?.menuNeedsUpdate?(menu); menu.update() }
        }
    }
    private static func check(_ condition: Bool, _ message: String) { results.append("\(condition ? "PASS" : "FAIL"): \(message)") }
    /// An item of a top-level menu, in it or in one of its submenus (Language ▸ S ▸ Swift).
    private static func item(_ title: String, menu: String) -> NSMenuItem? {
        guard let submenu = NSApp.mainMenu?.items.first(where: { $0.title == menu })?.submenu else { return nil }
        func find(in menu: NSMenu) -> NSMenuItem? {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
            defer { menu.delegate?.menuDidClose?(menu) }
            for entry in menu.items {
                if entry.title == title { return entry }
                if let nested = entry.submenu, let found = find(in: nested) { return found }
            }
            return nil
        }
        return find(in: submenu)
    }
    private static func click(_ title: String, menu: String) {
        guard let entry = item(title, menu: menu), let parent = entry.menu else { check(false, "Missing \(menu) > \(title)"); return }
        parent.performActionForItem(at: parent.index(of: entry))
    }
    private static func key(_ character: String, window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, characters: character, charactersIgnoringModifiers: character,
                                          isARepeat: false, keyCode: 0) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
    private static func verifyModal(key character: String, window: NSWindow, expected: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var completed = false
            panelObserver = { modal in
                panelObserver = nil
                let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
                    MainActor.assumeIsolated {
                    if expected == "open" {
                        check(modal is NSOpenPanel && modal.isVisible, "Cmd+O opens NSOpenPanel")
                    } else {
                        let text = descendants(modal.contentView).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
                        check(modal.isVisible && text.contains("Tidepad Preferences"), "Cmd+, opens Preferences placeholder")
                    }
                    if let panel = modal as? NSSavePanel { panel.cancel(nil) }
                    else if let button = descendants(modal.contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "OK" }) {
                        button.performClick(nil)
                    }
                    if !completed { completed = true; continuation.resume() }
                    }
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                RunLoop.main.add(timer, forMode: .default)
            }
            check(key(character, window: window), "Cmd+\(character) routed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard !completed else { return }
                completed = true
                panelObserver = nil
                check(false, "Timed out waiting for \(expected) panel")
                continuation.resume()
            }
        }
        window.makeKeyAndOrderFront(nil)
    }
    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }
    private static func allItems() -> [NSMenuItem] {
        func walk(_ menu: NSMenu?) -> [NSMenuItem] { menu?.items.flatMap { [$0] + walk($0.submenu) } ?? [] }
        return walk(NSApp.mainMenu)
    }
    private static func dump() -> String {
        func walk(_ menu: NSMenu?, depth: Int) -> [String] {
            menu?.items.flatMap { item in
                [String(repeating: "  ", count: depth) + "\(item.title) | key=\(item.keyEquivalent) flags=\(item.keyEquivalentModifierMask.rawValue) enabled=\(item.isEnabled) state=\(item.state.rawValue) action=\(item.action.map(NSStringFromSelector) ?? "nil")"] + walk(item.submenu, depth: depth + 1)
            } ?? []
        }
        return walk(NSApp.mainMenu, depth: 0).joined(separator: "\n")
    }
}
#endif
