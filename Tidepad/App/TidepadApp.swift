import SwiftUI
import AppKit

@main struct TidepadApp: App {
    @NSApplicationDelegateAdaptor(TidepadAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Tidepad", id: "workspace") {
            WorkspaceView(manager: delegate.manager, windowDelegate: delegate, sessions: delegate.sessions, preferences: delegate.preferences)
        }
        .defaultSize(width: 1000, height: 700)
        .commands { TidepadCommands(context: delegate.commandContext) }
    }
}

@MainActor final class TidepadAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let manager = DocumentManager()
    let sessions = EditorSessionStore()
    let preferences = EditorPreferences()
    lazy var commandContext = WorkspaceCommandContext(documents: manager, sessions: sessions, preferences: preferences)

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { NativeMenuCoordinator.arrange() }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async { NativeMenuCoordinator.arrange() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        manager.confirmCloseAll() ? .terminateNow : .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { manager.confirmCloseAll() }
    func application(_ application: NSApplication, open urls: [URL]) { manager.openInBackground(urls) }
}

struct WindowDelegateBridge: NSViewRepresentable {
    let delegate: TidepadAppDelegate
    func makeNSView(context: Context) -> NSView {
        let view = WindowObserverView()
        view.delegate = delegate
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowObserverView: NSView {
        weak var delegate: TidepadAppDelegate?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let delegate {
                delegate.commandContext.window = window
                window?.delegate = delegate
                window?.tabbingMode = .disallowed
                if let window { EditorDiagnostics.launched(window: window, context: delegate.commandContext) }
                #if DEBUG
                if let window {
                    VisualCapture.schedule(for: window, manager: delegate.manager)
                    MenuValidation.schedule(window: window, context: delegate.commandContext)
                    SearchValidation.schedule(window: window, context: delegate.commandContext)
                }
                #endif
            }
        }
    }
}
