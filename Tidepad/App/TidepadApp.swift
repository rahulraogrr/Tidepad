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
        // Tidepad ▸ Settings… (⌘,).
        Settings { PreferencesView(context: delegate.commandContext) }
    }
}

@MainActor final class TidepadAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let manager = DocumentManager()
    let sessions = EditorSessionStore()
    let preferences = EditorPreferences()
    let project = ProjectFolder()
    let terminal = TerminalPanel()
    lazy var claude = ClaudeCodeConnection(manager: manager, sessions: sessions, project: project)
    lazy var keeper = SessionKeeper(manager: manager, sessions: sessions, terminal: terminal)
    lazy var commandContext = WorkspaceCommandContext(documents: manager, sessions: sessions, preferences: preferences,
                                                      project: project, terminal: terminal)

    func applicationDidFinishLaunching(_ notification: Notification) {
        sessions.openFiles = { [weak self] urls in self?.open(urls) }
        // Find in Files searches the open folder.
        project.didOpen = { [weak self] folder in
            self?.commandContext.search.directory = folder.path
            self?.claude.folderChanged()
        }
        project.didClose = { [weak self] in self?.claude.folderChanged() }
        // Claude Code connects to Tidepad as it does to VS Code (see ClaudeCodeConnection).
        claude.start()
        sessions.selectionChanged = { [weak self] session in self?.claude.selectionChanged(in: session) }
        // Right-click ▸ On-Device AI in both editors.
        sessions.contextMenuItems = { [weak self] in self?.commandContext.ai.menuItems() ?? [] }
        // Reopen the last folder, unless Tidepad was launched to open one.
        if project.url == nil { project.restoreLastFolder() }
        if let folder = project.url { commandContext.search.directory = folder.path }
        // A new shell starts in the open folder, or else the current file's folder.
        terminal.workingDirectory = { [weak self] in
            self?.project.url ?? self?.manager.selectedDocument?.fileURL?.deletingLastPathComponent()
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        terminal.environment = { [weak self] in self?.claude.terminalEnvironment ?? [:] }
        // The saved theme, then the last session: tabs, unsaved text, the terminal panel.
        NSApp.appearance = preferences.appearance.appearance
        sessions.sessionCreated = { [weak self] session in self?.keeper.sessionCreated(session) }
        keeper.restore()
        keeper.startAutosave()
        DispatchQueue.main.async { NativeMenuCoordinator.arrange() }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async { NativeMenuCoordinator.arrange() }
    }
    /// Tidepad is a single-window app, like Notepad++: closing the workspace window quits.
    /// Quitting keeps unsaved tabs for next time (see SessionKeeper) instead of asking about each one;
    /// only if the session can't be written does Tidepad ask, as before.
    /// Set once the window has closed, so quitting doesn't do it twice.
    private var closeConfirmed = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if closeConfirmed { return .terminateNow }
        if keeper.save() { return .terminateNow }
        return manager.confirmCloseAll() ? .terminateNow : .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard keeper.save() || manager.confirmCloseAll() else { return false }
        closeConfirmed = true
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) { open(urls) }
    /// Removes the lock file, so Claude Code doesn't offer to connect to a Tidepad that has quit.
    func applicationWillTerminate(_ notification: Notification) { claude.stop() }

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
