import AppKit

/// Measures the normal editor (NSTextView) on a real file, to find what makes scrolling and ⌘↑/⌘↓
/// slow. Each step is timed with the syntax colouring on and off, and with line numbers on and off.
///
///   Tests/run-editor-performance.sh ~/Downloads/10mb.json
@main struct EditorPerformance {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(_ start: UInt64) -> Double { Double(now() - start) / 1e6 }

    @MainActor static func settle(_ window: NSWindow) {
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        window.displayIfNeeded()
    }

    @MainActor static func main() throws {
        guard CommandLine.arguments.count > 1 else { print("Usage: run-editor-performance.sh <file>"); return }
        let url = URL(fileURLWithPath: (CommandLine.arguments[1] as NSString).expandingTildeInPath)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var start = now()
        let document = try TextFileService().read(url)
        print(String(format: "read + decode: %.0f ms · %d lines · %d UTF-16 units", ms(start), document.lineCount, (document.text as NSString).length))

        for (label, colouring, numbers) in [("colours on, line numbers on", true, true), ("colours off, line numbers on", false, true),
                                              ("colours on, line numbers off", true, false), ("colours off, line numbers off", false, false)] {
            let session = EditorSession(document: document)
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1100, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = session.scrollView
            session.setLanguage(colouring ? document.syntaxLanguage : .plain)
            session.scrollView.rulersVisible = numbers
            window.orderFront(nil)
            window.makeFirstResponder(session.textView)
            start = now(); settle(window)
            let first = ms(start)
            var times: [Double] = []
            SyntaxHighlighter.timings = [:]
            for _ in 0..<150 {
                start = now()
                let clip = session.scrollView.contentView
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 45))
                session.scrollView.reflectScrolledClipView(clip)
                settle(window)
                times.append(ms(start))
            }
            times.sort()
            let parts = SyntaxHighlighter.timings.sorted { $0.key < $1.key }
                .map { String(format: "%@ %.1f", String($0.key.dropFirst(2)), Double($0.value) / 150 / 1e6) }.joined(separator: ", ")
            if !parts.isEmpty { print("    colouring per scroll step (ms): \(parts)") }
            start = now(); session.textView.moveToEndOfDocument(nil); settle(window); let end = ms(start)
            start = now(); session.textView.moveToBeginningOfDocument(nil); settle(window); let top = ms(start)
            start = now(); session.textView.moveToEndOfDocument(nil); settle(window); let end2 = ms(start)
            print(String(format: "%-30@ first screen %6.1f ms · scroll step median %5.1f ms, worst %6.1f ms · ⌘↓ %6.1f ms · ⌘↑ %6.1f ms · ⌘↓ again %6.1f ms",
                         label as NSString, first, times[times.count / 2], times.last ?? 0, end, top, end2))
            window.orderOut(nil)
            window.contentView = nil
        }
    }
}
