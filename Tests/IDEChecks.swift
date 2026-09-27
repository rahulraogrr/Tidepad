import Foundation

/// Claude Code's IDE protocol (with a stand-in editor) and the line diff behind the review window.
@MainActor final class FakeHost: IDEHost {
    var opened: [(String, Int?, String?, Bool)] = []
    var selection: IDESelection?
    var pendingDiff: ((Bool, String) -> Void)?
    var diffTabs: [String] = []
    func openFile(path: String, startLine: Int?, endLine: Int?, startText: String?, endText: String?, makeFrontmost: Bool) -> String? {
        if path.hasSuffix("missing.txt") { return "File not found: \(path)" }
        opened.append((path, startLine, startText, makeFrontmost)); return nil
    }
    func currentSelection() -> IDESelection? { selection }
    func latestSelection() -> IDESelection? { selection }
    func openTabs() -> [IDEEditorTab] { [IDEEditorTab(path: "/p/A.java", label: "A.java", languageID: "java", isActive: true, isDirty: true)] }
    func workspaceFolders() -> [String] { ["/p"] }
    func documentState(path: String) -> (isOpen: Bool, isDirty: Bool, isUntitled: Bool) { (path == "/p/A.java", true, false) }
    func saveDocument(path: String) -> Bool { path == "/p/A.java" }
    func reviewDiff(oldPath: String, newPath: String, newContents: String, tabName: String, decided: @escaping @MainActor (Bool, String) -> Void) {
        diffTabs.append(tabName); pendingDiff = decided
    }
    func closeDiff(tabName: String) -> Bool { diffTabs.removeAll { $0 == tabName }; return true }
    func closeAllDiffs() -> Int { defer { diffTabs = [] }; return diffTabs.count }
}

@main struct IDEChecks {
    @MainActor static func main() {
        let host = FakeHost()
        var sent: [[String: Any]] = []
        let ide = IDEProtocol(host: host) { data in
            sent.append(try! JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
            sent = []
            ide.receive(try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]))
            precondition(sent.count <= 1, "One reply per request")
            return sent.first ?? [:]
        }
        func call(_ id: Int, _ tool: String, _ arguments: [String: Any] = [:]) -> [String] {
            let reply = request(id, "tools/call", ["name": tool, "arguments": arguments])
            precondition(reply.isEmpty || (reply["id"] as? Int) == id, "Reply matches the request id")
            let content = (reply["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { $0["text"] as? String }
        }
        func json(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8)) }

        // Handshake and tool list.
        let initialize = request(1, "initialize", ["protocolVersion": "2025-03-26", "capabilities": [String: Any]()])
        let result = initialize["result"] as? [String: Any] ?? [:]
        precondition(result["protocolVersion"] as? String == "2025-03-26" && (result["serverInfo"] as? [String: Any])?["name"] as? String == "tidepad", "initialize")
        precondition((result["capabilities"] as? [String: Any])?["tools"] != nil)
        sent = []
        ide.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        precondition(sent.isEmpty, "Notifications get no reply")
        let tools = ((request(2, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        precondition(Set(tools) == ["openFile", "openDiff", "getCurrentSelection", "getLatestSelection", "getOpenEditors", "getWorkspaceFolders",
                                     "getDiagnostics", "checkDocumentDirty", "saveDocument", "close_tab", "closeAllDiffTabs"], "Tools: \(tools)")
        let unknown = request(3, "does/not/exist")
        precondition((unknown["error"] as? [String: Any])?["code"] as? Int == -32601, "Unknown methods are errors")
        precondition(request(4, "ping")["result"] != nil && request(5, "prompts/list")["result"] != nil)

        // Tools.
        precondition(call(10, "openFile", ["filePath": "/p/A.java", "startText": "class"]) == ["Opened file: /p/A.java"])
        precondition(host.opened.last?.0 == "/p/A.java" && host.opened.last?.2 == "class" && host.opened.last?.3 == true)
        let background = json(call(11, "openFile", ["filePath": "~/B.java", "makeFrontmost": false]).first ?? "{}") as? [String: Any]
        precondition(background?["success"] as? Bool == true && !(host.opened.last?.0.hasPrefix("~") ?? true), "~ expands; background open")
        let failed = request(12, "tools/call", ["name": "openFile", "arguments": ["filePath": "/p/missing.txt"]])
        precondition((failed["result"] as? [String: Any])?["isError"] as? Bool == true, "Errors are reported as tool errors")
        precondition((json(call(13, "getCurrentSelection")[0]) as? [String: Any])?["success"] as? Bool == false, "No selection")
        host.selection = IDESelection(text: "int x", filePath: "/p/A.java", startLine: 2, startCharacter: 4, endLine: 2, endCharacter: 9)
        let selection = json(call(14, "getCurrentSelection")[0]) as? [String: Any] ?? [:]
        let range = selection["selection"] as? [String: Any] ?? [:]
        precondition(selection["text"] as? String == "int x" && selection["fileUrl"] as? String == "file:///p/A.java" && range["isEmpty"] as? Bool == false, "Selection")
        precondition(((range["start"] as? [String: Any])?["character"] as? Int) == 4)
        let tabs = (json(call(15, "getOpenEditors")[0]) as? [String: Any])?["tabs"] as? [[String: Any]] ?? []
        precondition(tabs.first?["isDirty"] as? Bool == true && tabs.first?["uri"] as? String == "file:///p/A.java", "Open editors")
        let folders = json(call(16, "getWorkspaceFolders")[0]) as? [String: Any] ?? [:]
        precondition(folders["rootPath"] as? String == "/p" && (folders["folders"] as? [[String: Any]])?.first?["name"] as? String == "p", "Workspace folders")
        precondition((json(call(17, "checkDocumentDirty", ["filePath": "/p/A.java"])[0]) as? [String: Any])?["isDirty"] as? Bool == true)
        precondition((json(call(18, "saveDocument", ["filePath": "/p/A.java"])[0]) as? [String: Any])?["success"] as? Bool == true)
        precondition((json(call(19, "getDiagnostics")[0]) as? [Any])?.isEmpty == true)

        // openDiff blocks until the user decides.
        precondition(call(20, "openDiff", ["old_file_path": "/p/A.java", "new_file_path": "/p/A.java", "new_file_contents": "new", "tab_name": "✻ [Claude Code] A.java"]).isEmpty,
                     "No reply before the user decides")
        sent = []
        host.pendingDiff?(true, "new text")
        let accepted = ((sent.first?["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        precondition(sent.first?["id"] as? Int == 20 && accepted == ["FILE_SAVED", "new text"], "Accepted: \(accepted)")
        _ = call(21, "openDiff", ["old_file_path": "/p/A.java", "new_file_path": "/p/A.java", "new_file_contents": "x", "tab_name": "t2"])
        sent = []
        host.pendingDiff?(false, "")
        let rejected = ((sent.first?["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        precondition(rejected == ["DIFF_REJECTED", "t2"], "Rejected: \(rejected)")
        precondition(call(22, "closeAllDiffTabs") == ["CLOSED_2_DIFF_TABS"] && call(23, "close_tab", ["tab_name": "t2"]) == ["TAB_CLOSED"])

        // Notifications to Claude Code.
        sent = []
        ide.notify("selection_changed", params: host.selection!.json)
        precondition(sent.first?["method"] as? String == "selection_changed" && sent.first?["id"] == nil)

        // Line diff.
        let lines = LineDiff.lines(old: "a\nb\nc\nd\n", new: "a\nB\nc\nd\ne\n")
        precondition(lines == [.same("a", old: 1, new: 1), .removed("b", old: 2), .added("B", new: 2), .same("c", old: 3, new: 3),
                               .same("d", old: 4, new: 4), .added("e", new: 5)], "Diff: \(lines)")
        precondition(LineDiff.summary(lines) == (2, 1))
        precondition(LineDiff.lines(old: "", new: "x\n") == [.added("x", new: 1)] && LineDiff.lines(old: "x", new: "") == [.removed("x", old: 1)])
        precondition(LineDiff.lines(old: "a\r\nb\r\n", new: "a\nb\n").allSatisfy { if case .same = $0 { return true }; return false }, "CRLF")
        let long = (1...30).map { "line \($0)" }
        var changed = long; changed[14] = "changed"
        let hunks = LineDiff.hunks(LineDiff.lines(old: long.joined(separator: "\n"), new: changed.joined(separator: "\n")), context: 3)
        precondition(hunks.count == 10 && hunks.first! == nil && hunks.last! == nil, "One hunk with 3 lines of context each side: \(hunks.count)")
        precondition(LineDiff.hunks(LineDiff.lines(old: "same", new: "same")).isEmpty)
        print("IDE checks passed: Claude Code handshake, tool list, every tool, blocking openDiff (accept, reject), errors, notifications, line diff and hunks.")
    }
}
