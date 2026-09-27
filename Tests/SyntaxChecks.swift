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
            (.markdown, "# Heading\nText with `code` and **emphasis** [link](url)", [.heading, .string, .punctuation])
        ]
        for (language, source, expected) in fixtures {
            let document = SyntaxDocument(source, language)
            let tokens = document.tokens()
            for kind in expected { precondition(tokens.contains { $0.kind == kind }, "Missing \(kind) in \(language)") }
            precondition(tokens.allSatisfy { NSMaxRange($0.range) <= document.length })
        }

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
            precondition(document.state(line: 1).quote.isEmpty, "Quote state carried over in \(language)")
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
        print("Syntax checks passed: all 11 languages, JSON property names, lazy lexing and checkpoints, edits and random edits, long lines, UTF-16 offsets, brackets.")
    }
}
