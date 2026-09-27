import Darwin
import Foundation

/// A shell running on a pseudo-terminal, the way Terminal.app runs one: `forkpty` from macOS's C
/// library creates the terminal pair and the shell's process, which gets the terminal as its
/// controlling terminal, so job control and Ctrl-C work. Output arrives on the main queue.
final class PseudoTerminal {
    enum Failure: Error { case couldNotStart(Int32) }

    private(set) var processID: pid_t = 0
    private var descriptor: Int32 = -1
    private let queue = DispatchQueue(label: "Tidepad.PseudoTerminal")
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
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

    /// Starts the shell as a login shell (as Terminal.app does, so ~/.zprofile sets up PATH) in `directory`.
    func start(shell: String = PseudoTerminal.defaultShell(), directory: URL, columns: Int, rows: Int,
               environment extra: [String: String] = [:]) throws {
        var environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Tidepad"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        environment["PWD"] = directory.path

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

        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            // The child: the terminal is already its standard input, output and error.
            _ = chdir(workingDirectory)
            _ = execve(path, argv, envp)
            _exit(127)
        }
        guard pid > 0 else { throw Failure.couldNotStart(errno) }
        processID = pid
        descriptor = master

        let fd = master
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                DispatchQueue.main.async { self?.onOutput?(data) }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                reader.cancel() // The shell closed the terminal (EIO once it has exited).
            }
        }
        reader.setCancelHandler { close(fd) }
        readSource = reader
        reader.resume()

        let exitWatcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitWatcher.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0) // Reap the process.
            exitWatcher.cancel()
            DispatchQueue.main.async { self?.onExit?() }
        }
        exitSource = exitWatcher
        exitWatcher.resume()
    }

    /// Sends bytes to the shell (what the user types or pastes).
    func write(_ bytes: [UInt8]) {
        let fd = descriptor
        guard fd >= 0, !bytes.isEmpty else { return }
        queue.async { [weak self] in
            guard self?.readSource?.isCancelled == false else { return }
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { usleep(1_000); continue }
                    return
                }
                offset += written
            }
        }
    }

    /// Tells the shell (and the program running in it) the terminal's new size.
    func resize(columns: Int, rows: Int) {
        let fd = descriptor
        guard fd >= 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        queue.async { [weak self] in
            guard self?.readSource?.isCancelled == false else { return }
            // TIOCSWINSZ, _IOW('t', 103, struct winsize): a macro Swift can't import.
            _ = ioctl(fd, 0x8008_7467, &size)
        }
    }

    /// Ends the shell, as closing a Terminal.app window does.
    func terminate() {
        if processID > 0 { kill(processID, SIGHUP) }
        readSource?.cancel()
        onOutput = nil
        onExit = nil
    }

    deinit { terminate() }
}
