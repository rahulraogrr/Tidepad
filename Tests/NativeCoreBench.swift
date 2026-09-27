import AppKit
import Darwin

@main struct NativeCoreBench {
    static func rss() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now; let result = try body()
        let elapsed = start.duration(to: .now).components
        print("\(name)=\(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) ms RSS=\(rss())")
        return result
    }
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let kind = CommandLine.arguments.dropFirst().first ?? "io"
        let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1_000_000 : 1_000_000
        print("CASE \(kind) \(size)")
        if kind == "io" {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try String(repeating: "2026 INFO request=1234567890 successful response\n", count: size / 47).write(to: url, atomically: false, encoding: .utf8)
            for method in ["Data", "FileHandle", "mappedIfSafe"] {
                try autoreleasepool {
                    let data: Data = try measure(method + " read") {
                        if method == "FileHandle" {
                            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                            return try file.readToEnd() ?? Data()
                        }
                        return try Data(contentsOf: url, options: method == "mappedIfSafe" ? .mappedIfSafe : [])
                    }
                    let text = measure(method + " UTF8 decode") { String(data: data, encoding: .utf8) ?? "" }
                    let index = LineIndex()
                    measure("full index") { index.rebuild(text) }
                    let mutable = NSMutableString(string: text)
                    mutable.insert("x", at: 0)
                    measure("incremental index") { index.applyEdit(in: mutable, range: NSRange(location: 0, length: 1), delta: 1) }
                }
            }
            let automatic = try measure("Foundation encoding detection+decode") {
                var encoding = String.Encoding.utf8
                return try String(contentsOf: url, usedEncoding: &encoding)
            }
            _ = measure("legacy line ending scan") { LineEnding.detect(in: automatic) }
            return
        }
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        print("baseline RSS=\(rss())")
        let storage = NSTextStorage()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        var classic: NSLayoutManager?
        var modern: NSTextLayoutManager?
        var content: NSTextContentStorage?
        if kind == "tk2" {
            let provider = NSTextContentStorage(); provider.textStorage = storage
            let layout = NSTextLayoutManager(); provider.addTextLayoutManager(layout); layout.textContainer = container
            content = provider; modern = layout
        } else {
            let layout = NSLayoutManager(); layout.allowsNonContiguousLayout = kind == "tk1noncontiguous"
            layout.backgroundLayoutEnabled = false
            storage.addLayoutManager(layout); layout.addTextContainer(container); classic = layout
        }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 500), textContainer: container)
        textView.font = NSFont(name: "Menlo", size: 12)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isRichText = false; textView.allowsUndo = true
        textView.isHorizontallyResizable = true; textView.isVerticallyResizable = true
        let scroll = NSScrollView(frame: textView.frame); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = textView
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll; window.makeFirstResponder(textView)
        autoreleasepool {
            let text = String(repeating: "2026 INFO request=1234567890 successful response\n", count: size / 47)
            measure("storage population") { storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text) }
        }
        measure("first viewport layout") {
            classic?.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: 900, height: 500), in: container)
            modern?.textViewportLayoutController.layoutViewport()
            scroll.layoutSubtreeIfNeeded(); scroll.displayIfNeeded()
        }
        print("populated RSS=\(rss()) modern=\(textView.textLayoutManager != nil)")
        for (label, value) in [("ASCII", "x"), ("Unicode", "😀"), ("newline", "\n"), ("delete", "")] {
            textView.breakUndoCoalescing()
            measure(label) { textView.insertText(value, replacementRange: NSRange(location: 0, length: value.isEmpty ? 1 : 0)) }
        }
        measure("selection 100 moves") { for i in 0..<100 { textView.setSelectedRange(NSRange(location: i, length: 2)) } }
        measure("scroll 20 viewports") {
            for i in 0..<20 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: i * 200))
                scroll.reflectScrolledClipView(scroll.contentView)
                scroll.layoutSubtreeIfNeeded(); scroll.displayIfNeeded()
                modern?.textViewportLayoutController.layoutViewport()
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        measure("undo") { textView.undoManager?.undo() }
        measure("redo") { textView.undoManager?.redo() }
        withExtendedLifetime(content) {}
    }
}
