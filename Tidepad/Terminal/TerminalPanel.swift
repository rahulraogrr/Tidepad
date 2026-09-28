import AppKit
import Observation

/// One terminal in the panel: a shell on a pseudo-terminal, its screen and its view.
@MainActor @Observable final class TerminalSession: Identifiable {
    let id = UUID()
    /// 1, 2, 3… in the order terminals were opened, for tab names.
    let number: Int
    /// The window title the shell or program sets (usually the current folder or command).
    private(set) var title = ""
    private(set) var isRunning = false
    let screen: TerminalScreen
    @ObservationIgnored let view: TerminalView
    @ObservationIgnored private var shell: PseudoTerminal?
    @ObservationIgnored private let workingDirectory: @MainActor () -> URL
    @ObservationIgnored private let environment: @MainActor () -> [String: String]

    init(number: Int, workingDirectory: @escaping @MainActor () -> URL, environment: @escaping @MainActor () -> [String: String]) {
        self.number = number
        self.workingDirectory = workingDirectory
        self.environment = environment
        let font = NSFont(name: "Menlo", size: TidepadMetrics.editorFontSize)
            ?? .monospacedSystemFont(ofSize: TidepadMetrics.editorFontSize, weight: .regular)
        let screen = TerminalScreen()
        self.screen = screen
        view = TerminalView(screen: screen, font: font)
        view.send = { [weak self] bytes in self?.typed(bytes) }
        view.sizeChanged = { [weak self] columns, rows in self?.shell?.resize(columns: columns, rows: rows) }
        screen.respond = { [weak self] bytes in self?.shell?.write(bytes) }
        screen.bell = { NSSound.beep() }
        view.setAccessibilityLabel("Terminal, \(displayTitle)")
    }

    /// The tab's name: what the shell reports, or the shell's name and number.
    var displayTitle: String {
        title.isEmpty ? "\((PseudoTerminal.defaultShell() as NSString).lastPathComponent) \(number)" : title
    }

    func startIfNeeded() { if shell == nil && !isRunning { start() } }

    /// Ends the shell and starts a new one in the same tab.
    func restart() {
        shell?.terminate()
        shell = nil
        screen.reset()
        screen.clear()
        view.clearSelection()
        start()
    }

    /// Ends the shell, as closing a Terminal.app window does.
    func terminate() {
        shell?.terminate()
        shell = nil
        isRunning = false
    }

    private func start() {
        let terminal = PseudoTerminal()
        terminal.onOutput = { [weak self] data in self?.received(data) }
        terminal.onExit = { [weak self] in self?.exited() }
        do {
            try terminal.start(directory: workingDirectory(), columns: screen.columns, rows: screen.rows, environment: environment())
            shell = terminal
            isRunning = true
        } catch {
            screen.feed("Couldn't start \(PseudoTerminal.defaultShell()): \(error)\r\n")
            view.needsDisplay = true
        }
    }

    private func received(_ data: Data) {
        screen.feed(data)
        if screen.title != title {
            title = screen.title
            view.setAccessibilityLabel("Terminal, \(displayTitle)")
        }
        view.outputArrived()
    }

    private func exited() {
        shell = nil
        isRunning = false
        screen.feed("\r\n\u{1B}[0m[Process completed. Press Return for a new shell.]\r\n")
        view.needsDisplay = true
    }

    private func typed(_ bytes: [UInt8]) {
        if let shell { shell.write(bytes) }
        else if bytes.contains(0x0D) { screen.reset(); screen.clear(); start() }
    }
}

/// The terminal panel at the bottom of the window, with one or more terminals as tabs, as in VS Code.
/// A new terminal starts in the open folder (or the current file's folder). Hiding the panel keeps the
/// shells running; closing a tab ends its shell, and closing the last one hides the panel.
@MainActor @Observable final class TerminalPanel {
    private(set) var isVisible = false
    private(set) var sessions: [TerminalSession] = []
    private(set) var selectedID: UUID?
    /// Where a new shell starts.
    @ObservationIgnored var workingDirectory: @MainActor () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    /// Extra environment variables for new shells (the Claude Code connection's port).
    @ObservationIgnored var environment: @MainActor () -> [String: String] = { [:] }
    @ObservationIgnored private var nextNumber = 1

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } ?? sessions.last }

    // The selected terminal's parts, creating the first terminal if needed.
    var view: TerminalView { ensureSession().view }
    var screen: TerminalScreen { ensureSession().screen }
    var title: String { selected?.title ?? "" }
    var isRunning: Bool { selected?.isRunning ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        isVisible = true
        ensureSession().startIfNeeded()
        focus()
    }

    func hide() {
        if let view = selected?.view, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        isVisible = false
    }

    /// Opens another terminal as a new tab.
    func newTerminal() {
        let session = makeSession()
        sessions.append(session)
        selectedID = session.id
        isVisible = true
        session.startIfNeeded()
        focus()
    }

    func select(_ session: TerminalSession) {
        selectedID = session.id
        session.startIfNeeded()
        focus()
    }

    /// Closes a tab and ends its shell.
    func close(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let wasSelected = selected?.id == session.id
        if session.view.window?.firstResponder === session.view { session.view.window?.makeFirstResponder(nil) }
        session.terminate()
        sessions.remove(at: index)
        if sessions.isEmpty {
            selectedID = nil
            isVisible = false
        } else if wasSelected {
            selectedID = sessions[min(index, sessions.count - 1)].id
            focus()
        }
    }

    /// Restarts the selected terminal's shell.
    func restart() {
        ensureSession().restart()
        focus()
    }

    func focus() {
        guard let view = selected?.view else { return }
        if let window = view.window { window.makeFirstResponder(view) } else { view.focusWhenShown = true }
    }

    private func ensureSession() -> TerminalSession {
        if let selected { return selected }
        let session = makeSession()
        sessions.append(session)
        selectedID = session.id
        return session
    }

    private func makeSession() -> TerminalSession {
        defer { nextNumber += 1 }
        return TerminalSession(number: nextNumber, workingDirectory: { [weak self] in
            self?.workingDirectory() ?? FileManager.default.homeDirectoryForCurrentUser
        }, environment: { [weak self] in self?.environment() ?? [:] })
    }
}
