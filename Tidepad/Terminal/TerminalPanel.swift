import AppKit
import Observation

/// The terminal panel at the bottom of the window: one shell, started the first time the panel is
/// shown, in the open folder (or the current file's folder). Hiding the panel keeps the shell running,
/// as in VS Code.
@MainActor @Observable final class TerminalPanel {
    private(set) var isVisible = false
    /// The window title the shell or program sets (usually the current folder or command).
    private(set) var title = ""
    private(set) var isRunning = false
    /// Where a new shell starts.
    @ObservationIgnored var workingDirectory: @MainActor () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    /// Extra environment variables for new shells (the Claude Code connection's port).
    @ObservationIgnored var environment: @MainActor () -> [String: String] = { [:] }
    let screen = TerminalScreen()
    @ObservationIgnored private var shell: PseudoTerminal?
    @ObservationIgnored private var createdView: TerminalView?

    /// The terminal's view, created the first time it's needed.
    var view: TerminalView {
        if let createdView { return createdView }
        let view = makeView()
        createdView = view
        return view
    }

    private func makeView() -> TerminalView {
        let font = NSFont(name: "Menlo", size: TidepadMetrics.editorFontSize)
            ?? .monospacedSystemFont(ofSize: TidepadMetrics.editorFontSize, weight: .regular)
        let view = TerminalView(screen: screen, font: font)
        view.send = { [weak self] bytes in self?.typed(bytes) }
        view.sizeChanged = { [weak self] columns, rows in self?.shell?.resize(columns: columns, rows: rows) }
        screen.respond = { [weak self] bytes in self?.shell?.write(bytes) }
        screen.bell = { NSSound.beep() }
        return view
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        isVisible = true
        if shell == nil && !isRunning { start() }
        focus()
    }

    func hide() {
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        isVisible = false
    }

    func focus() {
        if let window = view.window { window.makeFirstResponder(view) } else { view.focusWhenShown = true }
    }

    /// Ends the shell and starts a new one.
    func restart() {
        shell?.terminate()
        shell = nil
        screen.reset()
        screen.clear()
        start()
        focus()
    }

    private func start() {
        _ = view // Connects the screen's replies before the shell writes anything.
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
        if screen.title != title { title = screen.title }
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
