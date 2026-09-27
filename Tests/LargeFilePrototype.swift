import AppKit
import Darwin

/// Large-file prototype: opens a big UTF-8 file in a plain NSTextView backed by
/// PieceTableTextStorage and measures what matters for editing 300–500 MB files.
///
///   Tests/run-large-file-prototype.sh [--mb 500] [--file path] [--textkit2] [--standard] [--relocate] [--skip-end] [--skip-undo] [--stay]
///
/// --standard uses Apple's default NSTextStorage with the whole file as one string (today's
/// approach) for comparison. --stay keeps the window open afterwards to scroll and type by hand.
@main struct LargeFilePrototype {
    static let arguments = CommandLine.arguments
    static func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    static var results: [String] = []

    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : 0
    }

    /// Lets AppKit lay out and draw, so timings include what the user would wait for.
    @MainActor static func settle(_ window: NSWindow) {
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.displayIfNeeded()
    }

    @MainActor @discardableResult
    static func measure<T>(_ label: String, _ window: NSWindow?, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        let value = try body()
        if let window { settle(window) }
        let line = String(format: "%-46@ %9.1f ms   RSS %5d MB", label as NSString, Date().timeIntervalSince(start) * 1000, residentMB())
        print(line); results.append(line)
        return value
    }

    /// Moves the view to a UTF-16 offset. With --relocate (TextKit 2) it uses the viewport
    /// controller's relocateViewport(to:), which lays out only the destination screen, instead of
    /// NSTextView's scrollRangeToVisible, which may lay out everything in between.
    @MainActor static func jump(_ textView: NSTextView, to offset: Int) {
        if arguments.contains("--relocate"), let layout = textView.textLayoutManager,
           let content = layout.textContentManager,
           let location = content.location(layout.documentRange.location, offsetBy: offset) {
            let y = layout.textViewportLayoutController.relocateViewport(to: location)
            textView.scroll(NSPoint(x: 0, y: y))
            layout.textViewportLayoutController.layoutViewport()
        } else {
            textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        }
    }

    static func generate(_ url: URL, megabytes: Int) throws {
        print("Generating \(megabytes) MB test file at \(url.path)…")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let block = Data((0..<10_000).map { k in
            "\(k): SELECT id, name FROM trades WHERE qty > \(k * 31) AND book = 'café 中文' -- line \(k)\n"
        }.joined().utf8)
        var written = 0
        while written < megabytes * 1_048_576 { try handle.write(contentsOf: block); written += block.count }
        try handle.close()
    }

    @MainActor static func main() throws {
        let megabytes = Int(value("--mb") ?? "500") ?? 500
        let url = value("--file").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-large-\(megabytes)mb.txt")
        if !FileManager.default.fileExists(atPath: url.path) { try generate(url, megabytes: megabytes) }
        let standard = arguments.contains("--standard")
        let textKit2 = arguments.contains("--textkit2")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("File: \(url.path) (\(size / 1_048_576) MB) · storage: \(standard ? "standard NSTextStorage" : "PieceTableTextStorage") · \(textKit2 ? "TextKit 2" : "TextKit 1")")
        print("RSS at start: \(residentMB()) MB")

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let font = NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]

        let storage: NSTextStorage = try measure("open (map + scan, or read + decode)", nil) {
            if standard {
                return NSTextStorage(string: try String(contentsOf: url, encoding: .utf8), attributes: attributes)
            }
            return PieceTableTextStorage(table: PieceTable(original: try MappedUTF8Text(url: url)), attributes: attributes)
        }

        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Tidepad large-file prototype — \(url.lastPathComponent)"
        let scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView: NSTextView = measure("create text view + attach storage", nil) {
            if textKit2 {
                let view = NSTextView(usingTextLayoutManager: true)
                view.textContentStorage?.textStorage = storage
                return view
            }
            let layout = NSLayoutManager()
            layout.allowsNonContiguousLayout = true
            layout.backgroundLayoutEnabled = false
            let container = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = false
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            return NSTextView(frame: scrollView.bounds, textContainer: container)
        }
        textView.frame = scrollView.bounds
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = font
        scrollView.documentView = textView
        window.contentView = scrollView

        measure("show window, first screen drawn", window) {
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            window.makeFirstResponder(textView)
        }
        let length = storage.length
        print("UTF-16 length: \(length)")
        let relocate = arguments.contains("--relocate")
        let jumpLabel = relocate ? "relocate viewport" : "scroll"
        measure("\(jumpLabel) to middle", window) { jump(textView, to: length / 2) }
        if arguments.contains("--skip-end") {
            print("(skipping jump to end)")
        } else {
            measure("\(jumpLabel) to end", window) { jump(textView, to: length) }
        }
        measure("\(jumpLabel) back to top", window) { jump(textView, to: 0) }

        let middle = (storage.string as NSString).lineRange(for: NSRange(location: length / 2, length: 0)).location
        measure("\(jumpLabel) to middle + place caret", window) {
            jump(textView, to: middle)
            textView.setSelectedRange(NSRange(location: middle, length: 0))
        }
        measure("type 100 characters at the middle (1 by 1)", window) {
            for _ in 0..<100 { textView.insertText("x", replacementRange: textView.selectedRange()) }
        }
        measure("delete 50 characters (backspace)", window) {
            for _ in 0..<50 { textView.deleteBackward(nil) }
        }
        let pasted = String(repeating: "pasted line of text\n", count: 52_429)
        let pasteLocation = textView.selectedRange().location
        measure("paste 1 MB at the middle", window) {
            textView.insertText(pasted, replacementRange: textView.selectedRange())
        }
        // The same change as undoing the paste, made directly on the storage: no NSTextView undo or
        // scrolling. Tells whether a slow undo comes from NSTextView or from TextKit 2 itself.
        let pastedRange = NSRange(location: pasteLocation, length: (pasted as NSString).length)
        measure("delete the 1 MB directly in the storage", window) { storage.replaceCharacters(in: pastedRange, with: "") }
        measure("re-insert the 1 MB directly in the storage", window) {
            storage.replaceCharacters(in: NSRange(location: pasteLocation, length: 0), with: pasted)
        }
        if arguments.contains("--skip-undo") {
            print("(skipping undo)")
        } else {
            measure("undo the paste (NSTextView)", window) { textView.undoManager?.undo() }
        }
        measure("\(jumpLabel) to top + type 1 character", window) {
            jump(textView, to: 0)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.insertText("y", replacementRange: NSRange(location: 0, length: 0))
        }
        measure("select all", window) { textView.selectAll(nil) }
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-prototype-saved.txt")
        try measure("save (streamed / whole string)", nil) {
            if let pieceStorage = storage as? PieceTableTextStorage {
                FileManager.default.createFile(atPath: out.path, contents: nil)
                let handle = try FileHandle(forWritingTo: out)
                try pieceStorage.table.writeUTF8(to: handle)
                try handle.close()
            } else {
                try storage.string.write(to: out, atomically: true, encoding: .utf8)
            }
        }
        try? FileManager.default.removeItem(at: out)

        let report = FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-prototype-report.txt")
        try? (results.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        print("Report: \(report.path)")
        if arguments.contains("--stay") {
            print("Window left open: scroll, type and undo by hand. Quit with ⌘Q.")
            let menu = NSMenu(), appItem = NSMenuItem()
            appItem.submenu = NSMenu()
            appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(appItem)
            let editItem = NSMenuItem()
            editItem.submenu = NSMenu(title: "Edit")
            editItem.submenu?.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            editItem.submenu?.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
            menu.addItem(editItem)
            app.mainMenu = menu
            app.run()
        }
    }
}
