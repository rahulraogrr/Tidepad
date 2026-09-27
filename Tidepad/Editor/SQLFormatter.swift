import Foundation

/// A Swift port of the layout rules of sql-formatter-plus (Standard SQL), the library behind the
/// "SQL Formatter" VS Code extension by adpyke, so Tidepad produces the same style:
///
///     select            -- top-level clauses on their own line, contents indented
///       a,              -- one column per line
///       b
///     from
///       t
///     where
///       x = 1
///       and y = 2;      -- AND / OR / JOIN / WHEN start new lines
///
/// Parenthesised expressions up to 50 characters stay inline (`count(*)`, `in (1, 2)`); longer
/// ones and CASE blocks are indented. Keyword case is kept unless `uppercase` is set.
struct SQLFormatter {
    struct Options {
        var indent = "  "
        var uppercase = false
        var linesBetweenQueries = 2
    }

    enum Kind: Equatable {
        case whitespace, lineComment, blockComment, string, openParen, closeParen, placeholder, number
        case topLevel, topLevelNoIndent, newline, reserved, word, op
    }

    struct Token: Equatable {
        let kind: Kind
        var value: String
    }

    // MARK: Word lists (from sql-formatter-plus StandardSqlFormatter)

    static let topLevelWords = ["ADD", "AFTER", "ALTER COLUMN", "ALTER TABLE", "DELETE FROM", "EXCEPT", "FETCH FIRST",
                                "FROM", "GROUP BY", "GO", "HAVING", "INSERT INTO", "INSERT", "LIMIT", "MODIFY", "ORDER BY",
                                "SELECT", "SET CURRENT SCHEMA", "SET SCHEMA", "SET", "UPDATE", "VALUES", "WHERE"]
    static let topLevelNoIndentWords = ["INTERSECT", "INTERSECT ALL", "MINUS", "UNION", "UNION ALL"]
    static let newlineWords = ["AND", "CROSS APPLY", "CROSS JOIN", "ELSE", "INNER JOIN", "JOIN", "LEFT JOIN", "LEFT OUTER JOIN",
                               "OR", "OUTER APPLY", "OUTER JOIN", "RIGHT JOIN", "RIGHT OUTER JOIN", "WHEN", "XOR"]
    /// Plain keywords only affect upper-casing, never layout.
    static let reservedWords = """
        ACTION ALL ANY AS ASC AUTO_INCREMENT AVG BEGIN BETWEEN BIGINT BINARY BLOB BOOLEAN BOTH BY CASCADE CAST CHAR \
        CHARACTER CHECK COALESCE COLLATE COLUMN COMMIT CONSTRAINT CONVERT COUNT CREATE CROSS CURRENT_DATE CURRENT_TIME \
        CURRENT_TIMESTAMP DATABASE DATE DATETIME DECIMAL DECLARE DEFAULT DELETE DESC DESCRIBE DISTINCT DOUBLE DROP EACH \
        ESCAPE EXISTS EXPLAIN FALSE FETCH FIRST FLOAT FOR FOREIGN FULL FUNCTION GRANT GROUP IF IFNULL IGNORE IN INDEX INNER \
        INT INTEGER INTERVAL INTO IS KEY LAST LEADING LEFT LIKE MAX MIN NATURAL NEXT NOT NULL NULLIF NUMERIC OFFSET ON ONLY \
        OUTER OVER PARTITION PRIMARY PROCEDURE RANGE RECURSIVE REFERENCES REPLACE RETURN RETURNS REVOKE RIGHT ROLLBACK ROW \
        ROWS SCHEMA SMALLINT SUM TABLE TEMPORARY TEXT THEN TIME TIMESTAMP TO TOP TRAILING TRANSACTION TRIGGER TRIM TRUE \
        TRUNCATE UNIQUE UNSIGNED USING VARCHAR VIEW WINDOW WITH
        """.split(separator: " ").map(String.init)

    private static let phrases: [String: Kind] = {
        var table: [String: Kind] = [:]
        for word in reservedWords { table[word] = .reserved }
        for word in newlineWords { table[word] = .newline }
        for word in topLevelWords { table[word] = .topLevel }
        for word in topLevelNoIndentWords { table[word] = .topLevelNoIndent }
        table["CASE"] = .openParen
        table["END"] = .closeParen
        return table
    }()
    private static let operators = ["->>", "<>", "!=", "<=", ">=", "||", "::", "->", "==", "=>", ":="]
    private static let inlineMaxLength = 50

    // MARK: Tokenizer

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    static func tokenize(_ text: String) -> [Token] {
        let c = Array(text)
        var tokens: [Token] = []
        var i = 0
        func next(_ offset: Int = 1) -> Character? { i + offset < c.count ? c[i + offset] : nil }
        func emit(_ kind: Kind, from start: Int) { tokens.append(Token(kind: kind, value: String(c[start..<i]))) }

        while i < c.count {
            let start = i, ch = c[i]
            if ch.isWhitespace {
                while i < c.count && c[i].isWhitespace { i += 1 }
                emit(.whitespace, from: start)
            } else if ch == "#" || (ch == "-" && next() == "-") {
                while i < c.count && !c[i].isNewline { i += 1 }
                if i < c.count { i += 1 } // The line break belongs to the comment.
                emit(.lineComment, from: start)
            } else if ch == "/" && next() == "*" {
                i += 2
                while i < c.count && !(c[i] == "*" && next() == "/") { i += 1 }
                i = min(c.count, i + 2)
                emit(.blockComment, from: start)
            } else if ch == "'" || ch == "\"" || ((ch == "N" || ch == "n") && next() == "'") {
                if ch == "N" || ch == "n" { i += 1 }
                let quote = c[i]
                i += 1
                while i < c.count {
                    if c[i] == "\\" { i += 2; continue }
                    if c[i] == quote {
                        if next() == quote { i += 2; continue } // Doubled quote escapes itself.
                        i += 1; break
                    }
                    i += 1
                }
                i = min(i, c.count)
                emit(.string, from: start)
            } else if ch == "`" {
                i += 1
                while i < c.count {
                    if c[i] == "`" { if next() == "`" { i += 2; continue }; i += 1; break }
                    i += 1
                }
                emit(.string, from: start)
            } else if ch == "[" {
                while i < c.count && c[i] != "]" { i += 1 }
                i = min(c.count, i + 1)
                emit(.string, from: start)
            } else if ch == "(" {
                i += 1; emit(.openParen, from: start)
            } else if ch == ")" {
                i += 1; emit(.closeParen, from: start)
            } else if ch == "?" {
                i += 1
                while i < c.count && c[i].isASCII && c[i].isNumber { i += 1 }
                emit(.placeholder, from: start)
            } else if (ch == "@" || ch == ":"), let following = next(), isWordCharacter(following) {
                i += 1
                while i < c.count && isWordCharacter(c[i]) { i += 1 }
                emit(.placeholder, from: start)
            } else if ch.isASCII && ch.isNumber {
                if ch == "0", let x = next(), x == "x" || x == "X" {
                    i += 2
                    while i < c.count && c[i].isHexDigit { i += 1 }
                } else {
                    while i < c.count && c[i].isASCII && c[i].isNumber { i += 1 }
                    if i < c.count && c[i] == ".", let d = next(), d.isASCII && d.isNumber {
                        i += 1
                        while i < c.count && c[i].isASCII && c[i].isNumber { i += 1 }
                    }
                    if i < c.count && (c[i] == "e" || c[i] == "E") {
                        var j = i + 1
                        if j < c.count && (c[j] == "+" || c[j] == "-") { j += 1 }
                        if j < c.count && c[j].isASCII && c[j].isNumber {
                            i = j
                            while i < c.count && c[i].isASCII && c[i].isNumber { i += 1 }
                        }
                    }
                }
                emit(.number, from: start)
            } else if isWordCharacter(ch) {
                let afterDot = tokens.last(where: { $0.kind != .whitespace })?.value == "."
                if !afterDot, let (kind, end) = reservedPhrase(in: c, at: i) {
                    i = end; emit(kind, from: start)
                } else {
                    while i < c.count && isWordCharacter(c[i]) { i += 1 }
                    emit(.word, from: start)
                }
            } else {
                let rest = String(c[i..<min(c.count, i + 3)])
                let length = operators.first(where: { rest.hasPrefix($0) })?.count ?? 1
                i += length
                emit(.op, from: start)
            }
        }
        return tokens
    }

    /// The longest keyword phrase (up to three words, any whitespace between) starting at `start`.
    private static func reservedPhrase(in c: [Character], at start: Int) -> (Kind, Int)? {
        var words: [(String, Int)] = []
        var i = start
        while words.count < 3 {
            let wordStart = i
            while i < c.count && isWordCharacter(c[i]) { i += 1 }
            guard i > wordStart else { break }
            words.append((String(c[wordStart..<i]).uppercased(), i))
            var j = i
            while j < c.count && c[j].isWhitespace { j += 1 }
            guard j > i, j < c.count, isWordCharacter(c[j]) else { break }
            i = j
        }
        for count in stride(from: words.count, through: 1, by: -1) {
            let phrase = words.prefix(count).map(\.0).joined(separator: " ")
            if let kind = phrases[phrase] { return (kind, words[count - 1].1) }
        }
        return nil
    }

    // MARK: Formatter

    static func format(_ text: String, options: Options = Options()) -> String {
        var formatter = Layout(tokens: tokenize(text), options: options)
        return formatter.run()
    }

    private struct Layout {
        let tokens: [Token]
        let options: Options
        var output = ""
        var indentTypes: [Bool] = [] // true = top-level indent, false = block (parenthesis) indent
        var inlineLevel = 0
        var previousReserved: Token?
        var index = 0

        init(tokens: [Token], options: Options) { self.tokens = tokens; self.options = options }

        mutating func run() -> String {
            for (position, original) in tokens.enumerated() {
                index = position
                let token = original
                switch token.kind {
                case .whitespace: break // Whitespace is re-created below.
                case .lineComment: output += token.value; addNewline()
                case .blockComment:
                    addNewline(); output += indentComment(token.value); addNewline()
                case .topLevel:
                    decreaseTopLevel(); addNewline(); indentTypes.append(true)
                    output += keyword(token.value); addNewline(); previousReserved = token
                case .topLevelNoIndent:
                    decreaseTopLevel(); addNewline(); output += keyword(token.value); addNewline(); previousReserved = token
                case .newline:
                    addNewline(); output += keyword(token.value) + " "; previousReserved = token
                case .reserved:
                    output += keyword(token.value) + " "; previousReserved = token
                case .openParen: openParenthesis(token)
                case .closeParen: closeParenthesis(token)
                case .placeholder, .string, .number, .word: output += token.value + " "
                case .op:
                    switch token.value {
                    case ",":
                        trimEnd(); output += ", "
                        let inLimit = previousReserved?.value.uppercased() == "LIMIT"
                        if inlineLevel == 0 && !inLimit { addNewline() }
                    case ":": trimEnd(); output += ": "
                    case ".": trimEnd(); output += "."
                    case ";":
                        indentTypes.removeAll()
                        trimEnd(); output += ";" + String(repeating: "\n", count: max(1, options.linesBetweenQueries))
                    default: output += token.value + " "
                    }
                }
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func keyword(_ value: String) -> String {
            let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return options.uppercase ? collapsed.uppercased() : collapsed
        }

        func indentComment(_ comment: String) -> String {
            var result = "", skipping = false
            let prefix = String(repeating: options.indent, count: indentTypes.count) + " "
            for character in comment {
                if skipping && (character == " " || character == "\t") { continue }
                skipping = false
                result.append(character)
                if character == "\n" { result += prefix; skipping = true }
            }
            return result
        }

        mutating func openParenthesis(_ token: Token) {
            let previous = index > 0 ? tokens[index - 1].kind : .whitespace
            // Keep the space before "(" only if the original had one: `count(*)` but `in (1, 2)`.
            if ![.whitespace, .openParen, .lineComment].contains(previous) { trimEnd() }
            output += options.uppercase ? token.value.uppercased() : token.value
            if inlineLevel > 0 { inlineLevel += 1 }
            else if isInlineBlock(from: index) { inlineLevel = 1 }
            if inlineLevel == 0 { indentTypes.append(false); addNewline() }
        }

        mutating func closeParenthesis(_ token: Token) {
            let value = options.uppercase ? token.value.uppercased() : token.value
            if inlineLevel > 0 {
                inlineLevel -= 1
                trimEnd(); output += value + " "
            } else {
                while let type = indentTypes.popLast(), type {} // Drop top-level indents inside the block too.
                addNewline(); output += value + " "
            }
        }

        func isInlineBlock(from start: Int) -> Bool {
            var length = 0, level = 0
            for token in tokens[start...] {
                length += token.value.count
                if length > inlineMaxLength { return false }
                if token.kind == .openParen { level += 1 }
                else if token.kind == .closeParen { level -= 1; if level == 0 { return true } }
                if [.topLevel, .newline, .lineComment, .blockComment].contains(token.kind) || token.value == ";" { return false }
            }
            return false
        }

        mutating func decreaseTopLevel() { if indentTypes.last == true { indentTypes.removeLast() } }

        mutating func trimEnd() {
            while let last = output.last, last == " " || last == "\t" { output.removeLast() }
        }

        mutating func addNewline() {
            trimEnd()
            if output.last != "\n" { output += "\n" }
            output += String(repeating: options.indent, count: indentTypes.count)
        }
    }
}
