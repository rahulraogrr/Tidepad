#if DEBUG
import AppKit

/// Opt-in visual QA only. Captures this app's view, never the desktop or another app.
@MainActor enum VisualCapture {
    private static var scheduled = false

    static func schedule(for window: NSWindow, manager: DocumentManager) {
        guard !scheduled, let directory = ProcessInfo.processInfo.environment["TIDEPAD_VISUAL_CAPTURE"] else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak window] in
            guard let window else { return }
            if let fixtures = ProcessInfo.processInfo.environment["TIDEPAD_VISUAL_FIXTURES"] {
                let base = URL(fileURLWithPath: fixtures)
                manager.open([base.appendingPathComponent("sample.json"), base.appendingPathComponent("Sample.swift")])
            }
            capture(window, directory: URL(fileURLWithPath: directory), index: 0, original: window.appearance)
        }
    }

    private static func capture(_ window: NSWindow, directory: URL, index: Int, original: NSAppearance?) {
        let names: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        guard index < names.count else {
            window.appearance = original
            return
        }
        let (label, name) = names[index]
        window.appearance = NSAppearance(named: name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let view = window.contentView else { return }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let captureRect = view.safeAreaRect
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: captureRect) {
                    view.cacheDisplay(in: captureRect, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: directory.appendingPathComponent("workspace-\(label).png"))
                    }
                }
                let font = EditorFontProvider.font()
                let report = "App: \(Bundle.main.bundleURL.path)\nPID: \(ProcessInfo.processInfo.processIdentifier)\nFont: \(font.fontName), \(font.pointSize) pt\nWindow content: \(view.bounds.size)\nToolbar: \(TidepadMetrics.toolbarHeight) pt\nTabs: \(TidepadMetrics.tabHeight) pt\nStatus: \(TidepadMetrics.statusBarHeight) pt\n"
                try report.write(to: directory.appendingPathComponent("runtime.txt"), atomically: true, encoding: .utf8)
            } catch { NSLog("Tidepad visual capture failed: %@", error.localizedDescription) }
            capture(window, directory: directory, index: index + 1, original: original)
        }
    }
}
#endif
