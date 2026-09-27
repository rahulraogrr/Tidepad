import Foundation
import Network
import Security

/// The server Claude Code connects to, as it connects to VS Code: a WebSocket on 127.0.0.1 only, on a
/// port the system picks, found through a lock file in ~/.claude/ide that also holds a random token.
/// A client must send the token in the `x-claude-code-ide-authorization` header, or the WebSocket
/// upgrade is refused. Built on Network.framework.
@MainActor final class IDEServer {
    private(set) var port: UInt16?
    private(set) var connectionCount = 0 { didSet { connectionsChanged?(connectionCount) } }
    var connectionsChanged: ((Int) -> Void)?
    weak var host: IDEHost?
    /// Written to the lock file: Claude Code offers to connect to editors whose folders contain its own.
    var workspaceFolders: [String] = [] { didSet { if oldValue != workspaceFolders { writeLockFile() } } }
    /// 128 random bits from the system's secure generator, as 32 lowercase hex digits.
    let token: String
    private let configDirectory: URL
    private var listener: NWListener?
    private var connections: [IDEConnection] = []
    private var pingTimer: Timer?

    /// `configDirectory` defaults to $CLAUDE_CONFIG_DIR or ~/.claude, as Claude Code uses.
    init(configDirectory: URL? = nil) {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        if let configDirectory {
            self.configDirectory = configDirectory
        } else if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            self.configDirectory = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            self.configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
    }

    var lockFile: URL? { port.map { configDirectory.appendingPathComponent("ide").appendingPathComponent("\($0).lock") } }

    func start() throws {
        guard listener == nil else { return }
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        let expected = token
        webSocket.setClientRequestHandler(.main) { _, headers in
            let authorized = headers.contains { $0.name.lowercased() == "x-claude-code-ide-authorization" && $0.value == expected }
            return NWProtocolWebSocket.Response(status: authorized ? .accept : .reject, subprotocol: nil, additionalHeaders: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        // Loopback only: nothing on the network can reach it, and macOS's firewall doesn't ask.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener?.port?.rawValue
                    self.writeLockFile()
                case .failed: self.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
        // Keep idle connections alive, as the VS Code extension does.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.connections.forEach { $0.ping() } }
        }
    }

    func stop() {
        pingTimer?.invalidate()
        pingTimer = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.close() }
        connections = []
        connectionCount = 0
        removeLockFile()
        port = nil
    }

    /// Sends a notification (e.g. selection_changed) to every connected Claude Code.
    func broadcast(_ method: String, params: [String: Any]) {
        connections.forEach { $0.handler.notify(method, params: params) }
    }

    private func accept(_ connection: NWConnection) {
        let client = IDEConnection(connection: connection, host: host) { [weak self] closed in
            self?.connections.removeAll { $0 === closed }
            self?.updateCount()
        }
        client.established = { [weak self] in self?.updateCount() }
        connections.append(client)
        client.start()
        // A client whose handshake was refused (no token) stalls; don't keep it around.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak client] in
            MainActor.assumeIsolated { if let client, !client.isEstablished { client.close() } }
        }
    }

    /// Only clients that have exchanged a message (so passed the token check) count as connected.
    private func updateCount() { connectionCount = connections.filter(\.isEstablished).count }

    private func writeLockFile() {
        guard let lockFile else { return }
        let directory = lockFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let contents: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "workspaceFolders": workspaceFolders,
            "ideName": "Tidepad",
            "transport": "ws",
            "authToken": token
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys]) else { return }
        // Readable only by the user: it holds the token.
        FileManager.default.createFile(atPath: lockFile.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockFile.path)
    }

    private func removeLockFile() {
        if let lockFile { try? FileManager.default.removeItem(at: lockFile) }
    }
}

/// One connected Claude Code: WebSocket text messages in and out of an IDEProtocol.
@MainActor final class IDEConnection {
    private let connection: NWConnection
    private(set) var handler: IDEProtocol!
    private let closed: (IDEConnection) -> Void
    private var finished = false
    /// Set once a message has arrived: the WebSocket handshake, and so the token check, succeeded.
    private(set) var isEstablished = false
    var established: (() -> Void)?

    init(connection: NWConnection, host: IDEHost?, closed: @escaping (IDEConnection) -> Void) {
        self.connection = connection
        self.closed = closed
        handler = IDEProtocol(host: host) { [weak self] data in self?.send(data) }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close { self.finish(); return }
                if let data, !data.isEmpty, metadata?.opcode == .text || metadata?.opcode == .binary {
                    if !self.isEstablished { self.isEstablished = true; self.established?() }
                    self.handler.receive(data)
                }
                if error == nil { self.receive() } else { self.finish() }
            }
        }
    }

    private func send(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func ping() {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(.main) { _ in }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() { connection.cancel() }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        closed(self)
    }
}
