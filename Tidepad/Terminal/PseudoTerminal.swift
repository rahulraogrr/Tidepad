import Darwin
import Foundation

/// A shell running on a pseudo-terminal, the way Terminal.app runs one: `forkpty` from macOS's C
/// library creates the terminal pair and the shell's process, which gets the terminal as its
/// controlling terminal, so job control and Ctrl-C work. Output arrives on the main queue, a chunk at
/// a time; input waits in memory while the terminal is full, so typing never blocks.
final class PseudoTerminal {
    enum Failure: Error { case couldNotStart(Int32) }

    /// The shell's process, or 0 once it has exited.
    private(set) var processID: pid_t = 0
    private var channel: Channel?
    /// Called on the main queue with each chunk the shell writes.
    var onOutput: ((Data) -> Void)?
    /// Called on the main queue when the shell exits.
    var onExit: (() -> Void)?

    /// The user's login shell.
    static func defaultShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    /// Variables the app was started with that describe the app's own launch, or another terminal it
    /// was started from, and would mislead programs in the shell.
    static let removedVariables: Set<String> = ["XPC_SERVICE_NAME", "XPC_FLAGS", "TERM_SESSION_ID",
                                                "OS_ACTIVITY_DT_MODE", "NSUnbufferedIO", "TERM_PROGRAM_VERSION"]
    static let removedPrefixes = ["__CF", "DYLD_", "TMUX", "ITERM_"]

    /// The shell's environment: the app's, without `removedVariables`, with `extra` and the terminal's own.
    static func environment(_ base: [String: String], adding extra: [String: String], directory: URL,
                            version: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) -> [String: String] {
        var environment = base.filter { key, _ in
            !removedVariables.contains(key) && !removedPrefixes.contains { key.hasPrefix($0) }
        }
        environment.merge(extra) { $1 }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Tidepad"
        if let version { environment["TERM_PROGRAM_VERSION"] = version }
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        environment["PWD"] = directory.path
        return environment
    }

    /// The signal a key sends (Ctrl-C, Ctrl-\ and Ctrl-Z), when it's typed on its own.
    static func signal(for bytes: [UInt8]) -> Int32? {
        switch bytes {
        case [0x03]: return SIGINT
        case [0x1C]: return SIGQUIT
        case [0x1A]: return SIGTSTP
        default: return nil
        }
    }

    /// Starts the shell as a login shell (as Terminal.app does, so ~/.zprofile sets up PATH) in `directory`.
    func start(shell: String = PseudoTerminal.defaultShell(), directory: URL, columns: Int, rows: Int,
               environment extra: [String: String] = [:]) throws {
        let environment = Self.environment(ProcessInfo.processInfo.environment, adding: extra, directory: directory)

        // Everything the child needs is prepared before forking: between fork and exec, only
        // async-signal-safe C calls are allowed.
        let path = strdup(shell)
        let workingDirectory = strdup(directory.path)
        let arguments = ["-" + (shell as NSString).lastPathComponent] // A leading "-" asks for a login shell.
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
        for (index, argument) in arguments.enumerated() { argv[index] = strdup(argument) }
        argv[arguments.count] = nil
        let variables = environment.map { "\($0.key)=\($0.value)" }
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: variables.count + 1)
        for (index, variable) in variables.enumerated() { envp[index] = strdup(variable) }
        envp[variables.count] = nil
        defer {
            free(path); free(workingDirectory)
            for index in 0..<arguments.count { free(argv[index]) }
            for index in 0..<variables.count { free(envp[index]) }
            argv.deallocate(); envp.deallocate()
        }
        let descriptorLimit = min(getdtablesize(), 65_536)

        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            // The child: the terminal is already its standard input, output and error. Everything else
            // the app has open (files, sockets, other terminals) is closed, so the shell and the programs
            // it runs don't inherit it.
            var other: Int32 = 3
            while other < descriptorLimit { close(other); other += 1 }
            _ = chdir(workingDirectory)
            _ = execve(path, argv, envp)
            _exit(127)
        }
        guard pid > 0 else { throw Failure.couldNotStart(errno) }
        // Not inherited by shells started later, and never blocks: a full terminal is written to
        // when it has room again.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        processID = pid

        let channel = Channel(descriptor: master, processID: pid)
        channel.onOutput = { [weak self] data in self?.onOutput?(data) }
        channel.onExit = { [weak self] in
            guard let self else { return }
            self.processID = 0
            self.channel = nil
            self.onExit?()
        }
        self.channel = channel
        channel.start()
    }

    /// Sends bytes to the shell (what the user types or pastes).
    func write(_ bytes: [UInt8]) {
        guard let channel, !bytes.isEmpty else { return }
        channel.queue.async { channel.send(bytes) }
    }

    /// Tells the shell (and the program running in it) the terminal's new size.
    func resize(columns: Int, rows: Int) {
        guard let channel else { return }
        let size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        channel.queue.async { channel.resize(size) }
    }

    /// Ends the shell, as closing a Terminal.app window does.
    func terminate() {
        onOutput = nil
        onExit = nil
        if let channel { channel.queue.async { channel.terminate() } }
        channel = nil
        processID = 0
    }

    deinit { terminate() }

    /// The terminal's descriptor and the dispatch sources that read it, write it and watch the shell,
    /// used only on `queue`. It lives until the shell has exited and been reaped, even after the
    /// PseudoTerminal is gone.
    private final class Channel {
        let queue = DispatchQueue(label: "Tidepad.PseudoTerminal")
        private let descriptor: Int32
        private let processID: pid_t
        /// Called on the main queue.
        var onOutput: ((Data) -> Void)?
        var onExit: (() -> Void)?

        private var reader: DispatchSourceRead?
        private var writer: DispatchSourceWrite?
        private var exitWatcher: DispatchSourceProcess?
        // A suspended source has to be resumed before it's cancelled, so the states are tracked.
        private var readerSuspended = false
        private var writerSuspended = true
        /// Bytes typed or pasted that the terminal had no room for yet.
        private var pending: [UInt8] = []
        private var pendingStart = 0
        private var openSources = 2
        private var closed = false
        private var exited = false

        init(descriptor: Int32, processID: pid_t) {
            self.descriptor = descriptor
            self.processID = processID
        }

        func start() {
            let fd = descriptor
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [self] in readAvailable() }
            reader.setCancelHandler { [self] in sourceCancelled() }
            let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            writer.setEventHandler { [self] in flush() }
            writer.setCancelHandler { [self] in sourceCancelled() }
            let exitWatcher = DispatchSource.makeProcessSource(identifier: processID, eventMask: .exit, queue: queue)
            exitWatcher.setEventHandler { [self] in processExited() }
            self.reader = reader
            self.writer = writer // Created suspended, and resumed only while bytes are waiting.
            self.exitWatcher = exitWatcher
            reader.resume()
            exitWatcher.resume()
        }

        private func readAvailable() {
            guard !closed, let reader else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let data = Data(buffer[0..<count])
                // One chunk at a time: the next is read once the main thread has taken this one, so a
                // program printing without end can't queue up more than the screen can take.
                reader.suspend()
                readerSuspended = true
                DispatchQueue.main.async { [self] in
                    onOutput?(data)
                    queue.async { [self] in resumeReading() }
                }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                close() // The shell closed the terminal (EIO once it has exited).
            }
        }

        private func resumeReading() {
            guard readerSuspended, let reader else { return }
            readerSuspended = false
            reader.resume()
        }

        func send(_ bytes: [UInt8]) {
            guard !closed else { return }
            if let signal = PseudoTerminal.signal(for: bytes), pendingStart < pending.count, !exited {
                // The terminal's input is full (a long paste the program isn't reading), so Ctrl-C would
                // wait behind it. As the terminal itself would: the rest of the paste is dropped, what the
                // terminal holds is flushed, and the program in the foreground gets the signal now.
                pending.removeAll()
                pendingStart = 0
                _ = tcflush(descriptor, TCIFLUSH)
                let group = tcgetpgrp(descriptor)
                _ = kill(group > 0 ? -group : processID, signal)
                flush()
                return
            }
            pending.append(contentsOf: bytes)
            flush()
        }

        /// Writes what the terminal has room for, and waits for room for the rest.
        private func flush() {
            guard !closed, let writer else { return }
            while pendingStart < pending.count {
                let written = pending[pendingStart...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                if written > 0 { pendingStart += written; continue }
                if written < 0 && errno == EINTR { continue }
                if written < 0 && errno != EAGAIN { pending.removeAll(); pendingStart = 0 } // The terminal is gone.
                break
            }
            if pendingStart >= pending.count {
                pending.removeAll()
                pendingStart = 0
                if !writerSuspended { writerSuspended = true; writer.suspend() }
            } else if writerSuspended {
                writerSuspended = false
                writer.resume()
            }
        }

        func resize(_ size: winsize) {
            guard !closed else { return }
            var size = size
            // TIOCSWINSZ, _IOW('t', 103, struct winsize): a macro Swift can't import.
            _ = ioctl(descriptor, 0x8008_7467, &size)
        }

        func terminate() {
            // Only while the shell hasn't been reaped: afterwards its process ID may belong to another.
            if !exited { kill(processID, SIGHUP) }
            close()
        }

        private func close() {
            guard !closed else { return }
            closed = true
            pending.removeAll()
            pendingStart = 0
            if readerSuspended { readerSuspended = false; reader?.resume() }
            if writerSuspended { writerSuspended = false; writer?.resume() }
            reader?.cancel()
            writer?.cancel()
        }

        /// The descriptor is closed once both sources using it have finished cancelling.
        private func sourceCancelled() {
            openSources -= 1
            if openSources == 0 {
                Darwin.close(descriptor)
                reader = nil
                writer = nil
            }
        }

        private func processExited() {
            var status: Int32 = 0
            waitpid(processID, &status, 0) // Reap the process.
            exited = true
            exitWatcher?.cancel()
            exitWatcher = nil
            DispatchQueue.main.async { [self] in onExit?() }
        }
    }
}
