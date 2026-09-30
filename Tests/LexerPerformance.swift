import Foundation

/// Measures the lexer (Tests/run-lexer-performance.sh [megabytes]): tokens and state-only speed on
/// UTF-16 lines for SQL, Swift, JSON and HTML (the normal editor's work), and the large-file view's
/// background pass over a SQL file of 4 × that size, lexing its bytes in place.
@main struct LexerPerformance {
    static func seconds(_ body: () -> Void) -> Double { let s = Date(); body(); return Date().timeIntervalSince(s) }
    static let samples: [(SyntaxLanguage, String)] = [
        (.sql, "INSERT INTO trades (id, name, qty, note) VALUES (42, 'Tidepad row', 1200, NULL); -- imported\n/* batch 7 */ SELECT id, name FROM trades WHERE qty > 100 AND name LIKE 'T%';\n"),
        (.swift, "    /* note */ let value = \"text\" + 42 // realistic Swift\n    if ready { return nil } else { self.count += 1 }\n"),
        (.json, "  {\"id\": 42, \"name\": \"Tidepad\", \"url\": \"https://example.com/a\", \"ok\": true, \"tags\": [1, 2, 3]},\n"),
        (.html, "<div class=\"row\" id=\"r42\"><a href=\"/x?y=1\">Tidepad &amp; friends</a><!-- note --></div>\n")
    ]
    static func main() throws {
        let megabytes = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 20
        for (language, record) in samples {
            let lines = String(repeating: record, count: megabytes * 1_048_576 / record.utf8.count).split(separator: "\n", omittingEmptySubsequences: false).map { Array(($0 + "\n").utf16) }
            let lexer = LineLexer(language: language)
            var state = LexerState(), tokens = 0
            let full = seconds { for line in lines { tokens += lexer.scan(line, state: &state).count } }
            state = LexerState()
            let stateOnly = seconds { for line in lines { _ = lexer.scan(line, state: &state, collect: false) } }
            print(String(format: "LEXER %@: %d lines, tokens %.0f MB/s (%.2f M lines/s), state only %.0f MB/s", language.displayName, lines.count,
                         Double(megabytes) / full, Double(lines.count) / full / 1e6, Double(megabytes) / stateOnly))
        }
        // The large-file background pass over a file.
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lexer-\(UUID().uuidString).sql")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let block = Data(String(repeating: samples[0].1, count: 1_048_576 / samples[0].1.utf8.count).utf8)
        for _ in 0..<(megabytes * 4) { handle.write(block) }
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = LargeTextBuffer(file: try LargeTextFile(url: url))
        var checkpoints = 0
        let pass = seconds {
            var state = LexerState()
            while true {
                let states = LargeSyntaxEngine.advance(language: .sql, from: checkpoints, state: state, count: 256,
                                                       lineCount: buffer.lineCount, lines: buffer.forEachLine)
                checkpoints += states.count
                if let last = states.last { state = last }
                if states.count < 256 { break }
            }
        }
        print(String(format: "LARGE PASS SQL %d MB (%d lines, %d checkpoints): %.2f s, %.0f MB/s", buffer.count >> 20, buffer.lineCount, checkpoints, pass, Double(buffer.count >> 20) / pass))
    }
}
