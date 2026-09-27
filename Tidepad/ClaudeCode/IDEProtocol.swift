import Foundation

/// A selection in an editor tab, as Claude Code expects it: 0-based lines, and characters counted in
/// UTF-16 units from the start of the line.
struct IDESelection: Equatable {
    var text: String
    var filePath: String
    var startLine: Int, startCharacter: Int
    var endLine: Int, endCharacter: Int
    var isEmpty: Bool { startLine == endLine && startCharacter == endCharacter }

    var json: [String: Any] {
        [
            "text": text,
            "filePath": filePath,
            "fileUrl": URL(fileURLWithPath: filePath).absoluteString,
            "selection": [
                "start": ["line": startLine, "character": startCharacter],
                "end": ["line": endLine, "character": endCharacter],
                "isEmpty": isEmpty
            ] as [String: Any]
        ]
    }
}

/// An open tab, for getOpenEditors.
struct IDEEditorTab {
    var path: String?
    var label: String
    var languageID: String
    var isActive: Bool
    var isDirty: Bool
}

/// What the editor provides to Claude Code. Implemented by the app (ClaudeCodeConnection) and by a
/// stand-in in checks.
@MainActor protocol IDEHost: AnyObject {
    /// Opens a file, selecting lines (1-based) or text if asked; returns an error message on failure.
    func openFile(path: String, startLine: Int?, endLine: Int?, startText: String?, endText: String?, makeFrontmost: Bool) -> String?
    func currentSelection() -> IDESelection?
    func latestSelection() -> IDESelection?
    func openTabs() -> [IDEEditorTab]
    func workspaceFolders() -> [String]
    /// Whether a file is open, has unsaved changes, and has never been saved.
    func documentState(path: String) -> (isOpen: Bool, isDirty: Bool, isUntitled: Bool)
    func saveDocument(path: String) -> Bool
    /// Shows a proposed change and calls `decided` once the user accepts (with the final text) or rejects it.
    func reviewDiff(oldPath: String, newPath: String, newContents: String, tabName: String,
                    decided: @escaping @MainActor (_ accepted: Bool, _ contents: String) -> Void)
    /// Closes a diff that's still open (Claude Code does this when the change was decided in the terminal).
    func closeDiff(tabName: String) -> Bool
    func closeAllDiffs() -> Int
}

/// Claude Code's IDE protocol, as spoken by VS Code and JetBrains: MCP (JSON-RPC 2.0) over a WebSocket.
/// Anthropic doesn't publish it; this follows the community documentation (claudecode.nvim's
/// PROTOCOL.md). Transport-free, so checks drive it directly: `receive` takes one message, `send`
/// writes one.
@MainActor final class IDEProtocol {
    weak var host: IDEHost?
    private let send: (Data) -> Void

    init(host: IDEHost?, send: @escaping (Data) -> Void) {
        self.host = host
        self.send = send
    }

    func receive(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else { return }
        let id = message["id"] // A number or string for requests; absent for notifications.
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            respond(id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": ["listChanged": true], "prompts": ["listChanged": true], "logging": [String: Any]()],
                "serverInfo": ["name": "tidepad", "version": "0.1"]
            ])
        case "tools/list": respond(id, result: ["tools": Self.tools])
        case "tools/call": callTool(params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:], id: id)
        case "prompts/list": respond(id, result: ["prompts": [Any]()])
        case "resources/list": respond(id, result: ["resources": [Any]()])
        case "ping": respond(id, result: [String: Any]())
        default:
            if method.hasPrefix("notifications/") || id == nil { return } // Notifications need no reply.
            write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32601, "message": "Method not found", "data": "Unknown method: \(method)"]])
        }
    }

    /// Tells Claude Code about something that happened in the editor, e.g. `selection_changed`.
    func notify(_ method: String, params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    // MARK: Tools

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }

    static let tools: [[String: Any]] = [
        tool("openFile", "Open a file in the editor and optionally select a range of text", [
            "filePath": ["type": "string", "description": "Path to the file to open"],
            "preview": ["type": "boolean", "description": "Whether to open the file in preview mode", "default": false],
            "startLine": ["type": "integer", "description": "Optional: line number to start the selection"],
            "endLine": ["type": "integer", "description": "Optional: line number to end the selection"],
            "startText": ["type": "string", "description": "Text pattern to find the start of the selection range. Selects from the beginning of this match."],
            "endText": ["type": "string", "description": "Text pattern to find the end of the selection range. Selects up to the end of this match. If not provided, only the startText match will be selected."],
            "selectToEndOfLine": ["type": "boolean", "description": "If true, selection will extend to the end of the line containing the endText match.", "default": false],
            "makeFrontmost": ["type": "boolean", "description": "Whether to make the file the active editor tab. If false, the file will be opened in the background without changing focus.", "default": true]
        ], required: ["filePath"]),
        tool("openDiff", "Open a diff view comparing old file content with new file content", [
            "old_file_path": ["type": "string", "description": "Path to the old file to compare"],
            "new_file_path": ["type": "string", "description": "Path to the new file to compare"],
            "new_file_contents": ["type": "string", "description": "Contents for the new file version"],
            "tab_name": ["type": "string", "description": "Name for the diff tab/view"]
        ], required: ["old_file_path", "new_file_path", "new_file_contents", "tab_name"]),
        tool("getCurrentSelection", "Get the current text selection in the active editor"),
        tool("getLatestSelection", "Get the most recent text selection (even if not in the active editor)"),
        tool("getOpenEditors", "Get information about currently open editors"),
        tool("getWorkspaceFolders", "Get all workspace folders currently open in the IDE"),
        tool("getDiagnostics", "Get language diagnostics from the editor", [
            "uri": ["type": "string", "description": "Optional file URI to get diagnostics for. If not provided, gets diagnostics for all files."]
        ]),
        tool("checkDocumentDirty", "Check if a document has unsaved changes (is dirty)", [
            "filePath": ["type": "string", "description": "Path to the file to check"]
        ], required: ["filePath"]),
        tool("saveDocument", "Save a document with unsaved changes", [
            "filePath": ["type": "string", "description": "Path to the file to save"]
        ], required: ["filePath"]),
        tool("close_tab", "Close a tab by name", [
            "tab_name": ["type": "string", "description": "Name of the tab to close"]
        ], required: ["tab_name"]),
        tool("closeAllDiffTabs", "Close all diff tabs in the editor")
    ]

    private func callTool(_ name: String, arguments: [String: Any], id: Any?) {
        guard let host else { return respondError(id, "The editor is not available") }
        switch name {
        case "openFile":
            guard let path = arguments["filePath"] as? String else { return respondError(id, "filePath is required") }
            let frontmost = arguments["makeFrontmost"] as? Bool ?? true
            if let error = host.openFile(path: Self.expand(path), startLine: arguments["startLine"] as? Int, endLine: arguments["endLine"] as? Int,
                                         startText: arguments["startText"] as? String, endText: arguments["endText"] as? String,
                                         makeFrontmost: frontmost) {
                return respondError(id, error)
            }
            if frontmost { respondText(id, "Opened file: \(path)") }
            else { respondJSON(id, ["success": true, "filePath": Self.expand(path)]) }
        case "openDiff":
            guard let oldPath = arguments["old_file_path"] as? String, let contents = arguments["new_file_contents"] as? String,
                  let tabName = arguments["tab_name"] as? String else { return respondError(id, "old_file_path, new_file_contents and tab_name are required") }
            let newPath = arguments["new_file_path"] as? String ?? oldPath
            // Blocking: the reply is sent once the user decides.
            host.reviewDiff(oldPath: Self.expand(oldPath), newPath: Self.expand(newPath), newContents: contents, tabName: tabName) { [weak self] accepted, final in
                self?.respondContent(id, accepted ? ["FILE_SAVED", final] : ["DIFF_REJECTED", tabName])
            }
        case "getCurrentSelection":
            if let selection = host.currentSelection() {
                respondJSON(id, selection.json.merging(["success": true]) { $1 })
            } else {
                respondJSON(id, ["success": false, "message": "No active editor found"])
            }
        case "getLatestSelection":
            if let selection = host.latestSelection() {
                respondJSON(id, selection.json.merging(["success": true]) { $1 })
            } else {
                respondJSON(id, ["success": false, "message": "No selection available"])
            }
        case "getOpenEditors":
            respondJSON(id, ["tabs": host.openTabs().map { tab -> [String: Any] in
                var entry: [String: Any] = ["label": tab.label, "languageId": tab.languageID, "isActive": tab.isActive, "isDirty": tab.isDirty]
                if let path = tab.path { entry["uri"] = URL(fileURLWithPath: path).absoluteString; entry["fileName"] = path }
                return entry
            }])
        case "getWorkspaceFolders":
            let folders = host.workspaceFolders()
            respondJSON(id, ["success": true, "rootPath": folders.first.map { $0 as Any } ?? NSNull(), "folders": folders.map { path -> [String: Any] in
                ["name": URL(fileURLWithPath: path).lastPathComponent, "uri": URL(fileURLWithPath: path).absoluteString, "path": path]
            }])
        case "getDiagnostics":
            respondJSON(id, [Any]()) // Tidepad isn't an IDE: no compiler or linter diagnostics.
        case "checkDocumentDirty":
            guard let path = arguments["filePath"] as? String else { return respondError(id, "filePath is required") }
            let state = host.documentState(path: Self.expand(path))
            guard state.isOpen else { return respondJSON(id, ["success": false, "message": "Document not open: \(path)"]) }
            respondJSON(id, ["success": true, "filePath": path, "isDirty": state.isDirty, "isUntitled": state.isUntitled])
        case "saveDocument":
            guard let path = arguments["filePath"] as? String else { return respondError(id, "filePath is required") }
            let saved = host.saveDocument(path: Self.expand(path))
            respondJSON(id, ["success": saved, "filePath": path, "saved": saved,
                             "message": saved ? "Document saved successfully" : "Document not open or couldn't be saved"])
        case "close_tab":
            _ = host.closeDiff(tabName: arguments["tab_name"] as? String ?? "")
            respondText(id, "TAB_CLOSED")
        case "closeAllDiffTabs":
            respondText(id, "CLOSED_\(host.closeAllDiffs())_DIFF_TABS")
        default:
            respondError(id, "Unknown tool: \(name)")
        }
    }

    private static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    // MARK: Replies

    private func respond(_ id: Any?, result: Any) {
        guard let id else { return }
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func respondContent(_ id: Any?, _ texts: [String]) {
        respond(id, result: ["content": texts.map { ["type": "text", "text": $0] }])
    }

    private func respondText(_ id: Any?, _ text: String) { respondContent(id, [text]) }

    private func respondJSON(_ id: Any?, _ value: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        respondText(id, String(decoding: data, as: UTF8.self))
    }

    private func respondError(_ id: Any?, _ message: String) {
        respond(id, result: ["content": [["type": "text", "text": message]], "isError": true])
    }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
        send(data)
    }
}
