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
    let project = ProjectFolder()
    lazy var commandContext = WorkspaceCommandContext(documents: manager, sessions: sessions, preferences: preferences, project: project)

    func applicationDidFinishLaunching(_ notification: Notification) {
        sessions.openFiles = { [weak self] urls in self?.open(urls) }
        // Find in Files searches the open folder.
        project.didOpen = { [weak self] folder in self?.commandContext.search.directory = folder.path }
        // Reopen the last folder, unless Tidepad was launched to open one.
        if project.url == nil { project.restoreLastFolder() }
        if let folder = project.url { commandContext.search.directory = folder.path }
        DispatchQueue.main.async { NativeMenuCoordinator.arrange() }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async { NativeMenuCoordinator.arrange() }
    }
    /// Tidepad is a single-window app, like Notepad++: closing the workspace window quits.
    /// Set once the close prompts have been answered, so quitting doesn't ask a second time.
    private var closeConfirmed = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if closeConfirmed { return .terminateNow }
        return manager.confirmCloseAll() ? .terminateNow : .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard manager.confirmCloseAll() else { return false }
        closeConfirmed = true
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) { open(urls) }

    /// Folders open as the project (the first one, if several); files open in tabs.
    func open(_ urls: [URL]) {
        let folders = urls.filter(ProjectFolder.isFolder)
        let files = urls.filter { !ProjectFolder.isFolder($0) }
        if let folder = folders.first { project.open(folder) }
        if !files.isEmpty { manager.openInBackground(files) }
    }
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
                delegate.commandContext.syncWindowDocumentState()
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
