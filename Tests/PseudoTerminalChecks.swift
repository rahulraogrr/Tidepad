import Darwin
import Foundation

/// The shell on a pseudo-terminal (macOS only): a real /bin/sh is started, typed to and ended.
@main struct PseudoTerminalChecks {
    static var output = ""
    static var exited = false

    /// Runs the main queue until `condition` holds, or fails after `seconds`.
    static func wait(_ seconds: Double, _ what: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            precondition(Date() < deadline, "Timed out: \(what). Output so far: \(output.suffix(400).debugDescription)")
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    static func main() {
        // The environment: the app's launch details and other terminals' variables aren't passed on.
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/x", "XPC_SERVICE_NAME": "app", "XPC_FLAGS": "0x0",
                    "__CF_USER_TEXT_ENCODING": "0x1F5:0:0", "DYLD_INSERT_LIBRARIES": "/x.dylib", "TMUX": "/tmp/t",
                    "TMUX_PANE": "%1", "ITERM_PROFILE": "Default", "TERM_SESSION_ID": "w0", "TERM_PROGRAM_VERSION": "447",
                    "LANG": "fr_FR.UTF-8"]
        let environment = PseudoTerminal.environment(base, adding: ["TIDEPAD_FILE": "/a"], directory: URL(fileURLWithPath: "/tmp"), version: "1.0")
        precondition(environment == ["PATH": "/usr/bin:/bin", "HOME": "/Users/x", "LANG": "fr_FR.UTF-8", "TIDEPAD_FILE": "/a",
                                     "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Tidepad",
                                     "TERM_PROGRAM_VERSION": "1.0", "PWD": "/tmp"], "Environment: \(environment)")
        precondition(PseudoTerminal.signal(for: [0x03]) == SIGINT && PseudoTerminal.signal(for: [0x1A]) == SIGTSTP
                     && PseudoTerminal.signal(for: [0x1C]) == SIGQUIT && PseudoTerminal.signal(for: [0x03, 0x03]) == nil)

        // Files the app has open aren't inherited by the shell.
        let open = (0..<8).map { _ in Darwin.open("/etc/hosts", O_RDONLY) }
        let terminal = PseudoTerminal()
        terminal.onOutput = { output += String(decoding: $0, as: UTF8.self) }
        terminal.onExit = { exited = true }
        try! terminal.start(shell: "/bin/sh", directory: URL(fileURLWithPath: NSTemporaryDirectory()), columns: 80, rows: 24)
        open.forEach { _ = close($0) }
        precondition(terminal.processID > 0)
        // The quotes keep the typed command's echo from matching.
        terminal.write(Array("echo F''D:$(ls /dev/fd | wc -l | tr -d ' ')\r".utf8))
        wait(10, "the descriptor count") { output.range(of: "FD:[0-9]+", options: .regularExpression) != nil }
        let match = output.range(of: "FD:[0-9]+", options: .regularExpression)!
        let count = Int(output[match].dropFirst(3))!
        precondition(count <= 5, "The shell inherited \(count) descriptors")

        // A big paste to a program that isn't reading doesn't block, and Ctrl-C still stops it at once.
        terminal.write(Array("sleep 30\r".utf8))
        Thread.sleep(forTimeInterval: 0.3)
        // Whole lines: the terminal holds a few KB of them and then makes the writer wait.
        terminal.write(Array(String(repeating: "a\r", count: 200_000).utf8))
        let interrupted = Date()
        terminal.write([0x03])
        terminal.write([0x15]) // Ctrl-U: whatever of the paste reached the shell's line.
        terminal.write(Array("echo D''ONE\r".utf8))
        wait(5, "Ctrl-C after a big paste") { output.contains("DONE\r\n") }
        precondition(Date().timeIntervalSince(interrupted) < 5)

        // A lot of output arrives in full.
        // (Only the end is searched: macOS terminals deliver output in small chunks.)
        output = ""
        let flood = Date()
        terminal.write(Array("yes 0123456789 | head -n 200000; echo E''ND\r".utf8))
        wait(30, "a lot of output") { output.utf8.suffix(64).contains(Array("END\r\n".utf8)) }
        let floodSeconds = Date().timeIntervalSince(flood)
        let lines = output.components(separatedBy: "0123456789\r\n").count - 1
        precondition(lines == 200_000, "\(lines) lines arrived")

        // Exit: reported once, with the process ID cleared.
        terminal.write(Array("exit\r".utf8))
        wait(10, "the shell to exit") { exited }
        precondition(terminal.processID == 0, "The exited shell's process ID is cleared")

        // Ending a running shell.
        let second = PseudoTerminal()
        try! second.start(shell: "/bin/sh", directory: URL(fileURLWithPath: "/"), columns: 80, rows: 24)
        let pid = second.processID
        second.terminate()
        wait(5, "the ended shell to go") { kill(pid, 0) != 0 }
        print(String(format: "Pseudo-terminal checks passed: environment, descriptors, Ctrl-C after a big paste, a lot of output (2.4 MB in %.2f s), exit and ending a shell.", floodSeconds))
    }
}
