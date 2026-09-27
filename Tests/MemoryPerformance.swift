import AppKit
import Darwin

@main struct MemoryPerformance {
    static func report(_ name: String) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        print("MEMORY \(name): \(result == KERN_SUCCESS ? info.resident_size : 0) bytes")
    }
    @MainActor static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let size = CommandLine.arguments.dropFirst().compactMap(Int.init).first ?? 1_000_000
        let empty = EditorSession(document: EditorDocument())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = empty.scrollView; window.makeFirstResponder(empty.textView); pump()
        report("empty editor")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
        defer { try? FileManager.default.removeItem(at: url) }
        try autoreleasepool {
            try String(repeating: "let value = 42 // example code with words\n", count: size / 41).write(to: url, atomically: false, encoding: .utf8)
        }
        let document = try autoreleasepool { try TextFileService().read(url) }
        report("decoded document + prepared index")
        let session = autoreleasepool { EditorSession(document: document) }
        window.contentView = session.scrollView; window.makeFirstResponder(session.textView); pump()
        report("live editor + first layout")
        // Wait for the debounced background lexer, where enabled.
        for _ in 0..<10 { pump() }
        report("syntax settled")
        autoreleasepool {
            let snapshot = document.text
            report("immutable search snapshot")
            session.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0)); pump()
            report("edit while snapshot retained")
            withExtendedLifetime(snapshot) {}
        }
        report("snapshot released")
        session.textView.selectAll(nil)
        report("select all cached metrics")
        _ = session.applySearchReplacement(range: NSRange(location: 0, length: session.textView.textStorage?.length ?? 0), text: "small replacement")
        pump(); report("bulk undo retained")
        session.textView.undoManager?.removeAllActions(); pump()
        report("undo released")
    }
}
