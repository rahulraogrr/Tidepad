import Foundation

/// A document for the engine: its text and an up-to-date line index, edited the way the editor edits.
final class SyntaxDocument {
    let text: NSMutableString
    let index = LineIndex()
    var engine: IncrementalSyntaxEngine
    init(_ string: String, _ language: SyntaxLanguage) {
        text = NSMutableString(string: string)
        index.rebuild(string)
        engine = IncrementalSyntaxEngine(language: language)
    }
    var length: Int { text.length }
    func tokens(_ range: NSRange? = nil) -> [SyntaxToken] {
        engine.tokens(in: range ?? NSRange(location: 0, length: text.length), index: index, text: text)
    }
    /// Tokens of one line, relative to the line's start.
    func tokens(line: Int) -> [SyntaxToken] {
        let start = index.starts[line]
        let end = line + 1 < index.starts.count ? index.starts[line + 1] : text.length
        return tokens(NSRange(location: start, length: end - start)).map {
            SyntaxToken(range: NSRange(location: $0.range.location - start, length: $0.range.length), kind: $0.kind)
        }
    }
    func state(line: Int) -> LexerState { engine.startState(ofLine: line, index: index, text: text) }
    func replace(_ range: NSRange, with string: String) {
        text.replaceCharacters(in: range, with: string)
        let delta = (string as NSString).length - range.length
        let edited = NSRange(location: range.location, length: (string as NSString).length)
        index.applyEdit(in: text, range: edited, delta: delta)
        engine.invalidate(fromLine: index.line(at: edited.location) - 1)
    }
}

@main struct SyntaxChecks {
    static func text(_ document: SyntaxDocument, _ token: SyntaxToken) -> String { document.text.substring(with: token.range) }

    /// The large-file view's engine gives the normal editor's tokens: exactly once the background pass
    /// has worked out the checkpoints, and the same when guessed, since no comment here spans more
    /// than the warm-up.
    /// Lines as the large-file view reads them: bytes with a line break.
    static func reader(_ lines: [String]) -> LargeSyntaxEngine.Lines {
        let bytes = lines.map { Array(($0 + "\n").utf8) }
        return { first, count, body in
            for line in first..<min(bytes.count, first + count) where !bytes[line].withUnsafeBufferPointer(body) { return }
        }
    }

    /// The lexer gives the same tokens and states on UTF-8 bytes as on UTF-16, and the same state
    /// when it only follows the state (which skips lines where nothing opens).
    static func encodingChecks() {
        let pieces = ["/*", "*/", "//", "--", "#", "'", "\"", "\"\"\"", "`", "```", "<", ">", "<!--", "-->", "\\", " ", "\t", "select", "SELECT",
                      "Null", "true", "func", "é", "తెలుగు", "😀", "42", "3.14", "a_b", "key:", ": ", "- ", "{", "}", "x", "div", "class=", "\r", "yes"]
        for language in SyntaxLanguage.allCases {
            let lexer = LineLexer(language: language)
            for _ in 0..<400 {
                var utf16 = LexerState(), utf8 = LexerState(), follow = LexerState()
                for _ in 0..<10 {
                    var line = ""
                    for _ in 0..<Int.random(in: 0...12) { line += pieces.randomElement()! }
                    line += "\n"
                    let units = Array(line.utf16), bytes = Array(line.utf8)
                    let a = lexer.scan(units, state: &utf16)
                    let b = bytes.withUnsafeBufferPointer { lexer.scan(utf8: $0, state: &utf8) }
                    _ = bytes.withUnsafeBufferPointer { lexer.scan(utf8: $0, state: &follow, collect: false) }
                    precondition(a.count == b.count && zip(a, b).allSatisfy { x, y in x.kind == y.kind
                        && String(decoding: units[x.range.location..<NSMaxRange(x.range)], as: UTF16.self) == String(decoding: bytes[y.range.location..<NSMaxRange(y.range)], as: UTF8.self) },
                                 "UTF-8 tokens in \(language): \(line.debugDescription)")
                    precondition(utf16 == utf8 && utf8 == follow, "States in \(language) after \(line.debugDescription)")
                }
            }
        }
    }

    static func largeEngineChecks() {
        var lines: [String] = []
        for k in 0..<2_000 {
            switch k % 97 {
            case 10: lines.append("/* comment opened on line \(k)")
            case 11...14: lines.append("still comment \(k) select from")
            case 15: lines.append("closed */ select \(k) from t where x = 'a'")
            default: lines.append("select id, name from t\(k) where n = \(k) and s = 'x' -- note")
            }
        }
        let document = SyntaxDocument(lines.joined(separator: "\n") + "\n", .sql)
        let units = lines.map { Array($0.utf16) + [10] }
        let lineUnits = reader(lines)
        var engine = LargeSyntaxEngine(language: .sql)
        let states = LargeSyntaxEngine.advance(language: .sql, from: 0, state: LexerState(), count: 1_000, lineCount: lines.count, lines: lineUnits)
        precondition(states.count == 2_000 / LargeSyntaxEngine.stride && states[0] == document.state(line: 256), "Background states")
        precondition(engine.append(states, after: 0) && !engine.append(states, after: 0), "Checkpoints append only in order")
        for line in [0, 5, 10, 12, 15, 16, 255, 256, 300, 687, 700, 1_000, 1_500, 1_791, 1_999] + (0..<60).map({ _ in Int.random(in: 0..<2_000) }) {
            precondition(engine.isExact(line) && engine.tokens(line: line, units: units[line], lines: lineUnits) == document.tokens(line: line), "Large line \(line)")
        }
        var guessed = LargeSyntaxEngine(language: .sql)
        for line in stride(from: 0, to: 2_000, by: 37) {
            precondition(guessed.isExact(line) == (line < LargeSyntaxEngine.stride), "Exact \(line)")
            precondition(guessed.tokens(line: line, units: units[line], lines: lineUnits) == document.tokens(line: line), "Guessed line \(line)")
        }
        // A comment opened far above: guessed wrong until the background pass reaches it.
        var long = ["/* opened"] + Array(repeating: "inside select", count: 500) + ["*/ select 1"]
        long += Array(repeating: "select 2", count: 100)
        let longUnits = long.map { Array($0.utf16) + [10] }
        let longLine = reader(long)
        var far = LargeSyntaxEngine(language: .sql)
        precondition(far.tokens(line: 400, units: longUnits[400], lines: longLine).first?.kind != .comment && !far.isExact(400), "Guessed outside the comment")
        precondition(far.append(LargeSyntaxEngine.advance(language: .sql, from: 0, state: LexerState(), count: 10, lineCount: long.count, lines: longLine), after: 0))
        precondition(far.tokens(line: 400, units: longUnits[400], lines: longLine).map(\.kind) == [.comment] && far.isExact(400), "Exact inside the comment")
        // An edit drops the checkpoints after it.
        engine.invalidate(fromLine: 600)
        precondition(engine.checkpoints.count == 600 / LargeSyntaxEngine.stride + 1, "Invalidated")
        // JSON: no state across lines, so every line is exact.
        var json = LargeSyntaxEngine(language: .json)
        let property = Array("  \"key\": [1, true],".utf16) + [10]
        precondition(json.isExact(1_000_000) && json.tokens(line: 1_000_000, units: property, lines: { _, _, _ in }).first?.kind == .property, "JSON")
    }

    static func main() {
        let fixtures: [(SyntaxLanguage, String, [SyntaxKind])] = [
            (.swift, "let value = \"hi\" // note\nvar ready = true\nlet count = 42", [.keyword, .string, .comment, .literal, .number, .punctuation]),
            (.java, "public class Demo { String s = \"hi\"; /* note */ int n = 42; boolean b = false; }", [.keyword, .string, .comment, .literal, .number, .punctuation]),
            (.json, "{\"name\": \"hi\", \"n\": 42, \"b\": true, \"x\": null}", [.property, .string, .number, .literal, .punctuation]),
            (.xml, "<!-- note -->\n<item id=\"42\">text</item>", [.comment, .tag, .string, .punctuation]),
            (.sql, "SELECT * FROM items WHERE n = 42 AND name = 'hi' AND enabled = TRUE; -- note", [.keyword, .string, .comment, .literal, .number, .punctuation]),
            (.javascript, "const text = `hi`; let n = 42; // note\nlet b = null;", [.keyword, .string, .comment, .literal, .number, .punctuation]),
            (.typescript, "interface Demo { name: string; } const n = 42; /* note */ const s = 'hi'; const b = false;", [.keyword, .string, .comment, .literal, .number, .punctuation]),
            (.html, "<!-- note --> <div class=\"demo\">Hello</div>", [.comment, .tag, .string, .punctuation]),
            (.css, "/* note */ .item { color: 'red'; width: 42px; display: flex; }", [.comment, .keyword, .number, .string, .punctuation]),
            (.yaml, "name: \"hello\" # note\ncount: 42\nenabled: true\nvalue: null", [.keyword, .string, .number, .comment, .literal, .punctuation]),
            (.markdown, "# Heading\nText with `code` and **emphasis** [link](url)", [.heading, .string, .punctuation]),
            (.python, "def greet(name):  # note\n    return f\"hi {name}\" if True else None\nx = 42", [.keyword, .string, .comment, .number, .punctuation])
        ]
        for (language, source, expected) in fixtures {
            let document = SyntaxDocument(source, language)
            let tokens = document.tokens()
            for kind in expected { precondition(tokens.contains { $0.kind == kind }, "Missing \(kind) in \(language)") }
            precondition(tokens.allSatisfy { NSMaxRange($0.range) <= document.length })
        }

        // Python: triple-quoted strings with either quote span lines; # inside a string isn't a comment;
        // a one-line string left open doesn't run on.
        let python = SyntaxDocument("x = \'\'\'one # not a comment\ntwo\n\'\'\' # done\ndoc = \"\"\"a\nb\"\"\"\nbad = 'open\ny = 1\n", .python)
        precondition(python.tokens(line: 1).map(\.kind) == [.string] && python.tokens(line: 0).last?.kind == .string, "Python \'\'\' spans lines")
        precondition(python.tokens(line: 2).map(\.kind) == [.string, .comment], "Python \'\'\' closes, then a comment")
        precondition(python.tokens(line: 4).first?.kind == .string, "Python \"\"\" spans lines")
        precondition(python.tokens(line: 6).contains { $0.kind == .number } && !python.tokens(line: 6).contains { $0.kind == .string },
                     "A one-line Python string ends with its line")
        precondition(SyntaxLanguage(fileExtension: "py") == .python && SyntaxLanguage(fileExtension: "PYI") == .python, "Python extensions")

        // JSON: property names versus string values, including escaped quotes and a colon later on the line.
        let json = SyntaxDocument("{\n  \"na\\\"me\" : \"a: b\",\n  \"list\": [\"x\", \"y\"],\n  \"url\": \"https://example.com\"\n}\n", .json)
        let strings = json.tokens().filter { $0.kind == .property || $0.kind == .string }
        let named = strings.map { "\($0.kind == .property ? "P" : "S")\(text(json, $0))" }
        precondition(named == ["P\"na\\\"me\"", "S\"a: b\"", "P\"list\"", "S\"x\"", "S\"y\"", "P\"url\"", "S\"https://example.com\""], "JSON strings: \(named)")

        // JSON lines never carry state, so any line can be coloured without lexing the lines before it.
        var state = LexerState()
        for line in ["{\"a\": \"open\n", "\"b\": 1 /* x\n", "\"c\": 'q\n", "<!-- x\n", "`y\n"] {
            _ = LineLexer(language: .json).scan(line, state: &state)
            precondition(state == LexerState(), "JSON carries no state across lines: \(line)")
        }
        let lateJSON = SyntaxDocument(String(repeating: "{\"k\": \"v\"},\n", count: 5_000), .json)
        _ = lateJSON.tokens(NSRange(location: lateJSON.length - 100, length: 100))
        precondition(lateJSON.engine.scannedLineCount < 20, "JSON colours the end without lexing the rest")

        // Prose apostrophes must not open strings that swallow the following lines.
        let prose: [(SyntaxLanguage, String)] = [
            (.yaml, "description: Don't use this\nnext: 42"),
            (.html, "<p>It's here</p>\n<div class=\"x\">42</div>"),
            (.xml, "<note>the author's file</note>\n<item id=\"1\"/>"),
            (.markdown, "It's a \"quoted\" word\nNext line")
        ]
        for (language, source) in prose {
            let document = SyntaxDocument(source, language)
            precondition(!document.tokens(line: 0).contains { $0.kind == .string && $0.range.length > 3 }, "Apostrophe opened a string in \(language)")
            precondition(document.state(line: 1).quote == 0, "Quote state carried over in \(language)")
        }
        // Markup: the tag name is a tag, later names in the tag are attributes.
        let markup = SyntaxDocument("<div class=\"x\" id='y'>text</div>", .html)
        let kinds = markup.tokens().filter { $0.kind == .tag || $0.kind == .attribute }.map(\.kind)
        precondition(kinds == [.tag, .attribute, .attribute, .tag], "Tag and attribute names: \(kinds)")
        let yaml = SyntaxDocument("a: 'quoted'\n- \"x\"\nc: [\"y\", 'z']", .yaml)
        precondition((0..<3).allSatisfy { line in yaml.tokens(line: line).contains { $0.kind == .string } }, "YAML quoted scalars remain strings")

        // Multi-line state, UTF-16 offsets and edits that change it.
        let source = "let emoji = \"😀\"\n/* start\ncontinued\n*/\nlet n = 42\n"
        let swift = SyntaxDocument(source, .swift)
        precondition(swift.tokens(line: 2).allSatisfy { $0.kind == .comment } && !swift.tokens(line: 2).isEmpty)
        let number = swift.tokens().first { $0.kind == .number }!
        precondition(text(swift, number) == "42", "UTF-16 offsets after an emoji")
        swift.replace(swift.text.range(of: "/* start"), with: "// start")
        precondition(!swift.tokens(line: 2).contains { $0.kind == .comment }, "Multi-line state must invalidate later lines")
        swift.replace(NSRange(location: 0, length: 0), with: "let n = 1\n")
        precondition(swift.tokens() == SyntaxDocument(swift.text as String, .swift).tokens(), "Incremental equals fresh")

        // Laziness: colouring the top of a long file lexes only the lines it needs.
        let lines = (0..<10_000).map { "let value\($0) = \($0) /* c */" }
        let long = SyntaxDocument(lines.joined(separator: "\n") + "\n", .swift)
        _ = long.tokens(NSRange(location: 0, length: 200))
        precondition(long.engine.scannedLineCount < 20, "Only the visible lines are lexed: \(long.engine.scannedLineCount)")
        // Jumping to the end lexes up to it once; a second look re-lexes at most a checkpoint's worth.
        let endRange = NSRange(location: long.length - 200, length: 200)
        _ = long.tokens(endRange)
        let afterJump = long.engine.scannedLineCount
        precondition(afterJump >= 9_990 && afterJump < 10_100, "Jump lexes forward once: \(afterJump)")
        _ = long.tokens(endRange)
        precondition(long.engine.scannedLineCount - afterJump <= IncrementalSyntaxEngine.checkpointStride + 10, "Checkpoints are reused")
        // An edit near the end keeps the states before it; one near the top discards the rest.
        let beforeEdit = long.engine.scannedLineCount
        long.replace(NSRange(location: long.length - 100, length: 0), with: "x")
        _ = long.tokens(endRange)
        precondition(long.engine.scannedLineCount - beforeEdit < 2 * IncrementalSyntaxEngine.checkpointStride + 10, "Edit near the end re-lexes little")
        long.replace(NSRange(location: 3, length: 0), with: "/*")
        let afterOpen = long.tokens(endRange)
        precondition(afterOpen.allSatisfy { $0.kind == .comment } && !afterOpen.isEmpty, "An opened comment reaches the end")
        long.replace(NSRange(location: 3, length: 2), with: "")
        precondition(long.tokens(endRange) == SyntaxDocument(long.text as String, .swift).tokens(endRange), "Closing it restores the colours")

        // Random edits: incremental colouring always equals colouring from scratch.
        var seed: UInt64 = 7
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return bound <= 0 ? 0 : Int((seed >> 33) % UInt64(bound))
        }
        let pieces = ["/*", "*/", "\"", "\n", "let ", "x", " 42 ", "//", "\r\n", "😀", "'", "\"\"\""]
        let fuzz = SyntaxDocument((0..<400).map { _ in pieces[random(pieces.count)] }.joined(), .swift)
        for step in 0..<300 {
            let at = random(fuzz.length + 1)
            var length = min(random(4), fuzz.length - at)
            if at + length < fuzz.length, (0xDC00...0xDFFF).contains(fuzz.text.character(at: at + length)) { length += 1 }
            if at > 0, at < fuzz.length, (0xDC00...0xDFFF).contains(fuzz.text.character(at: at)) { continue }
            fuzz.replace(NSRange(location: at, length: length), with: random(3) == 0 ? "" : pieces[random(pieces.count)])
            let start = random(fuzz.length + 1)
            let window = NSRange(location: start, length: min(fuzz.length - start, 1 + random(300)))
            precondition(fuzz.tokens(window) == SyntaxDocument(fuzz.text as String, .swift).tokens(window), "Random edit \(step)")
        }

        // Over-long lines are skipped rather than lexed.
        let minified = SyntaxDocument("let a = 1\n" + String(repeating: "\"x\", ", count: 30_000) + "\nlet b = 2\n", .swift)
        minified.engine.maximumLineLength = 1_000
        precondition(minified.tokens(line: 1).isEmpty && minified.tokens(line: 2).contains { $0.kind == .keyword })

        let plain = SyntaxDocument(source, .swift)
        plain.engine.setLanguage(.plain)
        precondition(plain.tokens().isEmpty)
        precondition(SyntaxDocument("", .swift).tokens().isEmpty)
        precondition(SyntaxLanguage(fileExtension: "JAVA") == .java)
        precondition(SyntaxLanguage(fileExtension: "txt") == .plain)
        let brackets = "😀({[x]})" as NSString
        precondition(BracketMatcher.match(in: brackets, caret: 2).map(\.location) == [2, 8])
        precondition(BracketMatcher.match(in: brackets, caret: 9).map(\.location) == [8, 2])
        precondition(BracketMatcher.match(in: "([)]", caret: 0).isEmpty)
        precondition(BracketMatcher.match(in: "(abc)", caret: 0, limit: 3).isEmpty)
        precondition(BracketMatcher.match(in: "", caret: 0).isEmpty)
        encodingChecks()
        largeEngineChecks()
        print("Syntax checks passed: all 12 languages, JSON property names, lazy lexing and checkpoints, edits and random edits, long lines, UTF-16 offsets, brackets; the same tokens and states from UTF-8 and UTF-16; the large-file view's colouring (exact from the background pass, guessed before it, after edits).")
    }
}
