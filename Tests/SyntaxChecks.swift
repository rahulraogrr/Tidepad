import Foundation

@main struct SyntaxChecks {
    static func main() {
        let fixtures: [(SyntaxLanguage, String, [SyntaxKind])] = [
            (.swift, "let value = \"hi\" // note\nvar ready = true\nlet count = 42", [.keyword, .string, .comment, .literal, .number, .punctuation]),
            (.java, "public class Demo { String s = \"hi\"; /* note */ int n = 42; boolean b = false; }", [.keyword, .string, .comment, .literal, .number, .punctuation]),
            (.json, "{\"name\": \"hi\", \"n\": 42, \"b\": true, \"x\": null}", [.string, .number, .literal, .punctuation]),
            (.xml, "<!-- note -->\n<item id=\"42\">text</item>", [.comment, .tag, .string, .punctuation]),
            (.sql, "SELECT * FROM items WHERE n = 42 AND name = 'hi' AND enabled = TRUE; -- note", [.keyword, .string, .comment, .literal, .number, .punctuation]),
            (.javascript, "const text = `hi`; let n = 42; // note\nlet b = null;", [.keyword, .string, .comment, .literal, .number, .punctuation]),
            (.typescript, "interface Demo { name: string; } const n = 42; /* note */ const s = 'hi'; const b = false;", [.keyword, .string, .comment, .literal, .number, .punctuation]),
            (.html, "<!-- note --> <div class=\"demo\">Hello</div>", [.comment, .tag, .string, .punctuation]),
            (.css, "/* note */ .item { color: 'red'; width: 42px; display: flex; }", [.comment, .keyword, .number, .string, .punctuation]),
            (.yaml, "name: \"hello\" # note\ncount: 42\nenabled: true\nvalue: null", [.keyword, .string, .number, .comment, .literal, .punctuation]),
            (.markdown, "# Heading\nText with `code` and **emphasis** [link](url)", [.heading, .string, .punctuation])
        ]
        for (language, text, expected) in fixtures {
            var engine = IncrementalSyntaxEngine()
            engine.update(text: text, language: language)
            let tokens = engine.tokens(in: NSRange(location: 0, length: (text as NSString).length))
            for kind in expected { precondition(tokens.contains { $0.kind == kind }, "Missing \(kind) in \(language)") }
            precondition(tokens.allSatisfy { NSMaxRange($0.range) <= (text as NSString).length })
        }
        // Prose apostrophes must not open strings that swallow the following lines.
        let prose: [(SyntaxLanguage, String)] = [
            (.yaml, "description: Don't use this\nnext: 42"),
            (.html, "<p>It's here</p>\n<div class=\"x\">42</div>"),
            (.xml, "<note>the author's file</note>\n<item id=\"1\"/>"),
            (.markdown, "It's a \"quoted\" word\nNext line")
        ]
        for (language, text) in prose {
            var engine = IncrementalSyntaxEngine()
            engine.update(text: text, language: language)
            precondition(!engine.lines[0].tokens.contains { $0.kind == .string && $0.range.length > 3 }, "Apostrophe opened a string in \(language)")
            precondition(engine.lines[1].incoming.quote.isEmpty, "Quote state carried over in \(language)")
        }
        var yaml = IncrementalSyntaxEngine()
        yaml.update(text: "a: 'quoted'\n- \"x\"\nc: [\"y\", 'z']", language: .yaml)
        precondition(yaml.lines.allSatisfy { $0.tokens.contains { $0.kind == .string } }, "YAML quoted scalars remain strings")
        var engine = IncrementalSyntaxEngine()
        let source = "let emoji = \"😀\"\n/* start\ncontinued\n*/\nlet n = 42\n"
        engine.update(text: source, language: .swift)
        precondition(engine.lines[2].tokens.allSatisfy { $0.kind == .comment })
        engine.update(text: source.replacingOccurrences(of: "42", with: "43"), language: .swift)
        precondition(engine.scannedLineCount == 1, "Unchanged lines should be reused")
        engine.update(text: source.replacingOccurrences(of: "/* start", with: "// start"), language: .swift)
        precondition(!engine.lines[2].tokens.contains { $0.kind == .comment }, "Multiline state must invalidate downstream lines")
        engine.update(text: "let n = 1\n" + source, language: .swift)
        let incremental = engine.tokens(in: NSRange(location: 0, length: 1000))
        var fresh = IncrementalSyntaxEngine()
        fresh.update(text: "let n = 1\n" + source, language: .swift)
        precondition(incremental == fresh.tokens(in: NSRange(location: 0, length: 1000)))
        engine.update(text: source, language: .plain)
        precondition(engine.tokens(in: NSRange(location: 0, length: 1000)).isEmpty)
        precondition(SyntaxLanguage(fileExtension: "JAVA") == .java)
        precondition(SyntaxLanguage(fileExtension: "txt") == .plain)
        let brackets = "😀({[x]})" as NSString
        precondition(BracketMatcher.match(in: brackets, caret: 2).map(\.location) == [2, 8])
        precondition(BracketMatcher.match(in: brackets, caret: 9).map(\.location) == [8, 2])
        precondition(BracketMatcher.match(in: "([)]", caret: 0).isEmpty)
        precondition(BracketMatcher.match(in: "(abc)", caret: 0, limit: 3).isEmpty)
        precondition(BracketMatcher.match(in: "", caret: 0).isEmpty)
        print("Syntax checks passed: all 11 languages, incremental reuse/state propagation, UTF-16 offsets, language changes, nested/mismatched/bounded brackets.")
    }
}
