import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

@main struct TextCommandChecks {
    /// Applies an edit to a copy of the text, returning the new text and selection.
    static func run(_ text: String, _ edit: TextEdit?) -> (String, NSRange)? {
        guard let edit else { return nil }
        let result = NSMutableString(string: text)
        precondition(NSMaxRange(edit.range) <= result.length, "Edit range inside the text")
        result.replaceCharacters(in: edit.range, with: edit.text)
        precondition(NSMaxRange(edit.selection) <= result.length, "Selection inside the result")
        return (result as String, edit.selection)
    }
    static func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }
    static func expect(_ actual: (String, NSRange)?, _ text: String, _ selection: NSRange? = nil, _ message: String) {
        guard let actual else { fatalError("\(message): expected an edit") }
        precondition(actual.0 == text, "\(message): got \(actual.0.debugDescription), expected \(text.debugDescription)")
        if let selection { precondition(actual.1 == selection, "\(message): selection \(actual.1)") }
    }

    static func main() throws {
        // Line block: a selection ending at the start of a line excludes that line.
        let abc = "a\nb\nc" as NSString
        precondition(TextCommands.lineBlock(abc, selection: NSRange(location: 0, length: 2)) == NSRange(location: 0, length: 2))
        precondition(TextCommands.lineBlock(abc, selection: NSRange(location: 1, length: 2)) == NSRange(location: 0, length: 4))
        precondition(TextCommands.lineBlock(abc, selection: caret(5)) == NSRange(location: 4, length: 1))

        // Duplicate
        var s = "a\nb\nc"
        expect(run(s, TextCommands.duplicateLines(s as NSString, selection: caret(2), lineEnding: "\n")), "a\nb\nb\nc", caret(2), "Duplicate middle line")
        expect(run(s, TextCommands.duplicateLines(s as NSString, selection: caret(4), lineEnding: "\n")), "a\nb\nc\nc", caret(4), "Duplicate last line without break")
        s = "x\r\ny\r\n"
        expect(run(s, TextCommands.duplicateLines(s as NSString, selection: NSRange(location: 0, length: 4), lineEnding: "\r\n")), "x\r\ny\r\nx\r\ny\r\n", nil, "Duplicate selected CRLF lines")
        expect(run("", TextCommands.duplicateLines("" as NSString, selection: caret(0), lineEnding: "\n")), "\n", nil, "Duplicate in empty document")

        // Delete
        s = "a\nb\nc"
        expect(run(s, TextCommands.deleteLines(s as NSString, selection: caret(2))), "a\nc", caret(2), "Delete middle line")
        expect(run(s, TextCommands.deleteLines(s as NSString, selection: caret(4))), "a\nb", caret(2), "Delete last line leaves no empty line")
        expect(run(s, TextCommands.deleteLines(s as NSString, selection: NSRange(location: 0, length: 3))), "c", caret(0), "Delete selected lines")
        expect(run("only", TextCommands.deleteLines("only" as NSString, selection: caret(1))), "", caret(0), "Delete only line")
        precondition(TextCommands.deleteLines("" as NSString, selection: caret(0)) == nil)

        // Move
        s = "one\ntwo\nthree"
        expect(run(s, TextCommands.moveLines(s as NSString, selection: caret(5), up: true)), "two\none\nthree", caret(1), "Move up keeps caret column")
        expect(run(s, TextCommands.moveLines(s as NSString, selection: caret(5), up: false)), "one\nthree\ntwo", caret(11), "Move down to last line")
        expect(run(s, TextCommands.moveLines(s as NSString, selection: caret(9), up: true)), "one\nthree\ntwo", caret(5), "Move last line up")
        precondition(TextCommands.moveLines(s as NSString, selection: caret(0), up: true) == nil, "First line can't move up")
        precondition(TextCommands.moveLines(s as NSString, selection: caret(9), up: false) == nil, "Last line can't move down")
        expect(run(s, TextCommands.moveLines(s as NSString, selection: NSRange(location: 0, length: 7), up: false)), "three\none\ntwo", NSRange(location: 6, length: 7), "Move a two-line block down")
        s = "a\r\nb\nc"
        expect(run(s, TextCommands.moveLines(s as NSString, selection: caret(3), up: true)), "b\r\na\nc", caret(0), "Line breaks stay in place")

        // Case
        s = "hello wORLD, don't"
        let all = NSRange(location: 0, length: (s as NSString).length)
        expect(run(s, TextCommands.convertCase(s as NSString, selection: all, to: .upper)), "HELLO WORLD, DON'T", all, "Uppercase")
        expect(run(s, TextCommands.convertCase(s as NSString, selection: all, to: .lower)), "hello world, don't", all, "Lowercase")
        let title = run(s, TextCommands.convertCase(s as NSString, selection: all, to: .title))
        precondition(title?.0.hasPrefix("Hello World, Don") == true, "Title case: \(String(describing: title?.0))")
        precondition(TextCommands.convertCase(s as NSString, selection: caret(3), to: .upper) == nil, "Case needs a selection")
        let sharp = "straße"
        expect(run(sharp, TextCommands.convertCase(sharp as NSString, selection: NSRange(location: 0, length: 6), to: .upper)), "STRASSE", NSRange(location: 0, length: 7), "Uppercase can change length")
        precondition(TextCommands.convertCase("ABC" as NSString, selection: NSRange(location: 0, length: 3), to: .upper) == nil, "No-op is not an edit")

        // Sort and duplicates
        s = "pear\napple\nBanana\napple\n"
        expect(run(s, TextCommands.sortLines(s as NSString, selection: caret(0), ascending: true, lineEnding: "\n")), "Banana\napple\napple\npear\n", caret(0), "Sort whole document, case-sensitive")
        expect(run(s, TextCommands.sortLines(s as NSString, selection: caret(0), ascending: false, lineEnding: "\n")), "pear\napple\napple\nBanana\n", nil, "Sort descending")
        expect(run(s, TextCommands.removeDuplicateLines(s as NSString, selection: caret(0), lineEnding: "\n")), "pear\napple\nBanana\n", nil, "Remove duplicates keeps first")
        s = "c\nb\na"
        expect(run(s, TextCommands.sortLines(s as NSString, selection: caret(0), ascending: true, lineEnding: "\n")), "a\nb\nc", nil, "Sort keeps missing final break")
        s = "z\nc\nb\na\n"
        expect(run(s, TextCommands.sortLines(s as NSString, selection: NSRange(location: 2, length: 4), ascending: true, lineEnding: "\n")), "z\nb\nc\na\n", NSRange(location: 2, length: 4), "Sort only selected lines")
        precondition(TextCommands.sortLines("a\nb\n" as NSString, selection: caret(0), ascending: true, lineEnding: "\n") == nil, "Already sorted is not an edit")

        // JSON
        s = "{\"b\":1,\"a\":[1, 2.50,{}],\"s\":\"x, {y}: \\\"z\\\"\",\"e\":[]}\n"
        let json = try TextCommands.formatJSON(s as NSString, selection: caret(0), indent: "  ", lineEnding: "\n")
        expect(run(s, json), "{\n  \"b\": 1,\n  \"a\": [\n    1,\n    2.50,\n    {}\n  ],\n  \"s\": \"x, {y}: \\\"z\\\"\",\n  \"e\": []\n}\n", caret(0), "Format JSON keeps key order, numbers and strings")
        let formatted = run(s, json)!.0
        let again = try TextCommands.formatJSON(formatted as NSString, selection: caret(0), indent: "  ", lineEnding: "\n")
        precondition(again == nil, "Formatting is idempotent")
        do {
            _ = try TextCommands.formatJSON("{\"a\": }" as NSString, selection: caret(0), indent: "  ", lineEnding: "\n")
            fatalError("Invalid JSON must throw")
        } catch is TextCommandFailure {}

        // XML
        s = "<root><!-- note --><item id=\"1\">text</item><empty/></root>"
        let xml = try TextCommands.formatXML(s as NSString, selection: caret(0), lineEnding: "\n")
        let pretty = run(s, xml)!.0
        precondition(!pretty.hasPrefix("<?xml"), "No declaration added")
        precondition(pretty.contains("\n") && pretty.contains("<!-- note -->") && pretty.contains("<item id=\"1\">text</item>"), "Format XML: \(pretty)")
        let reparsed = try XMLDocument(xmlString: pretty, options: [])
        precondition(reparsed.rootElement()?.childCount == 3 || reparsed.rootElement()?.children?.count == 3, "Same nodes after formatting")
        do {
            _ = try TextCommands.formatXML("<a><b></a>" as NSString, selection: caret(0), lineEnding: "\n")
            fatalError("Malformed XML must throw")
        } catch is TextCommandFailure {}

        // SQL, in the style of the "SQL Formatter" VS Code extension (sql-formatter-plus).
        s = "select a, count(*) as n from users u left join orders o on o.user_id = u.id where u.active = 1 and u.role in ('admin', 'owner') group by a order by n desc limit 10, 20;\n"
        let sqlExpected = """
            select
              a,
              count(*) as n
            from
              users u
              left join orders o on o.user_id = u.id
            where
              u.active = 1
              and u.role in ('admin', 'owner')
            group by
              a
            order by
              n desc
            limit
              10, 20;

            """
        let sql = TextCommands.formatSQL(s as NSString, selection: caret(0), indent: "  ", lineEnding: "\n")
        expect(run(s, sql), sqlExpected, caret(0), "Format SQL")
        precondition(TextCommands.formatSQL(sqlExpected as NSString, selection: caret(0), indent: "  ", lineEnding: "\n") == nil, "SQL formatting is idempotent")
        s = "SELECT CASE WHEN x > 0 THEN 'it''s' ELSE 'no' END AS s FROM t -- note\r\nWHERE t.select = :id"
        let sqlCase = TextCommands.formatSQL(s as NSString, selection: caret(0), indent: "    ", lineEnding: "\r\n")
        expect(run(s, sqlCase), "SELECT\r\n    CASE\r\n        WHEN x > 0 THEN 'it''s'\r\n        ELSE 'no'\r\n    END AS s\r\nFROM\r\n    t -- note\r\nWHERE\r\n    t.select = :id", nil, "SQL CASE blocks, comments, placeholders and CRLF")
        let upper = SQLFormatter.format("select a from t where b is not null union all select 1", options: .init(uppercase: true))
        precondition(upper == "SELECT\n  a\nFROM\n  t\nWHERE\n  b IS NOT NULL\nUNION ALL\nSELECT\n  1", "Uppercase keywords: \(upper)")
        let queries = SQLFormatter.format("select 1; select 2;")
        precondition(queries == "select\n  1;\n\nselect\n  2;", "Blank line between queries: \(queries.debugDescription)")

        print("Text command checks passed: duplicate/delete/move lines, case, sort, remove duplicates, format JSON/XML/SQL.")
    }
}
