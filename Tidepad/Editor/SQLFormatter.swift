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
        /// Length in UTF-8 bytes (the inline-block rule's measure; equal to sql-formatter's UTF-16 length
        /// for ASCII). Whitespace tokens keep only
        /// their length; their text is never used, so it isn't copied.
        var length: Int

        init(kind: Kind, value: String, length: Int? = nil) {
            self.kind = kind
            self.value = value
            self.length = length ?? value.utf8.count
        }
    }

    // MARK: Word lists (from sql-formatter-plus StandardSqlFormatter)

    static let topLevelWords = ["ADD", "AFTER", "ALTER COLUMN", "ALTER TABLE", "DELETE FROM", "EXCEPT", "FETCH FIRST",
                                "FROM", "GROUP BY", "GO", "HAVING", "INSERT INTO", "INSERT", "LIMIT", "MODIFY", "ORDER BY",
                                "SELECT", "SET CURRENT SCHEMA", "SET SCHEMA", "SET", "UPDATE", "VALUES", "WHERE"]
    static let topLevelNoIndentWords = ["INTERSECT", "INTERSECT ALL", "MINUS", "UNION", "UNION ALL"]
    static let newlineWords = ["AND", "CROSS APPLY", "CROSS JOIN", "ELSE", "INNER JOIN", "JOIN", "LEFT JOIN", "LEFT OUTER JOIN",
                               "OR", "OUTER APPLY", "OUTER JOIN", "RIGHT JOIN", "RIGHT OUTER JOIN", "WHEN", "XOR"]
    /// Plain keywords only affect upper-casing, never layout. The full list from sql-formatter-plus
    /// StandardSqlFormatter (272 entries; its "NOW()" entry matches the word NOW).
    static let reservedWords = [
        "ACCESSIBLE", "ACTION", "AGAINST", "AGGREGATE", "ALGORITHM", "ALL", "ALTER", "ANALYSE", "ANALYZE", "AS",
        "ASC", "AUTOCOMMIT", "AUTO_INCREMENT", "BACKUP", "BEGIN", "BETWEEN", "BINLOG", "BOTH", "CASCADE", "CASE",
        "CHANGE", "CHANGED", "CHARACTER SET", "CHARSET", "CHECK", "CHECKSUM", "COLLATE", "COLLATION", "COLUMN",
        "COLUMNS", "COMMENT", "COMMIT", "COMMITTED", "COMPRESSED", "CONCURRENT", "CONSTRAINT", "CONTAINS", "CONVERT",
        "CREATE", "CROSS", "CURRENT_TIMESTAMP", "DATABASE", "DATABASES", "DAY", "DAY_HOUR", "DAY_MINUTE",
        "DAY_SECOND", "DEFAULT", "DEFINER", "DELAYED", "DELETE", "DESC", "DESCRIBE", "DETERMINISTIC", "DISTINCT",
        "DISTINCTROW", "DIV", "DO", "DROP", "DUMPFILE", "DUPLICATE", "DYNAMIC", "ELSE", "ENCLOSED", "END", "ENGINE",
        "ENGINES", "ENGINE_TYPE", "ESCAPE", "ESCAPED", "EVENTS", "EXEC", "EXECUTE", "EXISTS", "EXPLAIN", "EXTENDED",
        "FAST", "FETCH", "FIELDS", "FILE", "FIRST", "FIXED", "FLUSH", "FOR", "FORCE", "FOREIGN", "FULL", "FULLTEXT",
        "FUNCTION", "GLOBAL", "GRANT", "GRANTS", "GROUP_CONCAT", "HEAP", "HIGH_PRIORITY", "HOSTS", "HOUR",
        "HOUR_MINUTE", "HOUR_SECOND", "IDENTIFIED", "IF", "IFNULL", "IGNORE", "IN", "INDEX", "INDEXES", "INFILE",
        "INSERT", "INSERT_ID", "INSERT_METHOD", "INTERVAL", "INTO", "INVOKER", "IS", "ISOLATION", "KEY", "KEYS",
        "KILL", "LAST_INSERT_ID", "LEADING", "LEVEL", "LIKE", "LINEAR", "LINES", "LOAD", "LOCAL", "LOCK", "LOCKS",
        "LOGS", "LOW_PRIORITY", "MARIA", "MASTER", "MASTER_CONNECT_RETRY", "MASTER_HOST", "MASTER_LOG_FILE", "MATCH",
        "MAX_CONNECTIONS_PER_HOUR", "MAX_QUERIES_PER_HOUR", "MAX_ROWS", "MAX_UPDATES_PER_HOUR",
        "MAX_USER_CONNECTIONS", "MEDIUM", "MERGE", "MINUTE", "MINUTE_SECOND", "MIN_ROWS", "MODE", "MODIFY", "MONTH",
        "MRG_MYISAM", "MYISAM", "NAMES", "NATURAL", "NOT", "NOW", "NULL", "OFFSET", "ON DELETE", "ON UPDATE", "ON",
        "ONLY", "OPEN", "OPTIMIZE", "OPTION", "OPTIONALLY", "OUTFILE", "PACK_KEYS", "PAGE", "PARTIAL", "PARTITION",
        "PARTITIONS", "PASSWORD", "PRIMARY", "PRIVILEGES", "PROCEDURE", "PROCESS", "PROCESSLIST", "PURGE", "QUICK",
        "RAID0", "RAID_CHUNKS", "RAID_CHUNKSIZE", "RAID_TYPE", "RANGE", "READ", "READ_ONLY", "READ_WRITE",
        "REFERENCES", "REGEXP", "RELOAD", "RENAME", "REPAIR", "REPEATABLE", "REPLACE", "REPLICATION", "RESET",
        "RESTORE", "RESTRICT", "RETURN", "RETURNS", "REVOKE", "RLIKE", "ROLLBACK", "ROW", "ROWS", "ROW_FORMAT",
        "SECOND", "SECURITY", "SEPARATOR", "SERIALIZABLE", "SESSION", "SHARE", "SHOW", "SHUTDOWN", "SLAVE", "SONAME",
        "SOUNDS", "SQL", "SQL_AUTO_IS_NULL", "SQL_BIG_RESULT", "SQL_BIG_SELECTS", "SQL_BIG_TABLES",
        "SQL_BUFFER_RESULT", "SQL_CACHE", "SQL_CALC_FOUND_ROWS", "SQL_LOG_BIN", "SQL_LOG_OFF", "SQL_LOG_UPDATE",
        "SQL_LOW_PRIORITY_UPDATES", "SQL_MAX_JOIN_SIZE", "SQL_NO_CACHE", "SQL_QUOTE_SHOW_CREATE", "SQL_SAFE_UPDATES",
        "SQL_SELECT_LIMIT", "SQL_SLAVE_SKIP_COUNTER", "SQL_SMALL_RESULT", "SQL_WARNINGS", "START", "STARTING",
        "STATUS", "STOP", "STORAGE", "STRAIGHT_JOIN", "STRING", "STRIPED", "SUPER", "TABLE", "TABLES", "TEMPORARY",
        "TERMINATED", "THEN", "TO", "TRAILING", "TRANSACTIONAL", "TRUE", "TRUNCATE", "TYPE", "TYPES", "UNCOMMITTED",
        "UNIQUE", "UNLOCK", "UNSIGNED", "USAGE", "USE", "USING", "VARIABLES", "VIEW", "WHEN", "WITH", "WORK",
        "WRITE", "YEAR_MONTH"
    ]

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

    // The tokenizer works on UTF-8 bytes, Swift's native string storage: SQL syntax is ASCII, and any
    // non-ASCII byte belongs to a word (identifiers, or text inside strings and comments). Scanning bytes
    // avoids per-Character grapheme segmentation, and making each token's String is a plain copy.
    private static func unit(_ scalar: Unicode.Scalar) -> UInt8 { UInt8(scalar.value) }
    private static func isWhitespace(_ u: UInt8) -> Bool { u == 0x20 || (0x09...0x0D).contains(u) }
    private static func isNewline(_ u: UInt8) -> Bool { (0x0A...0x0D).contains(u) }
    private static func isDigit(_ u: UInt8) -> Bool { u >= 0x30 && u <= 0x39 }
    private static func isHexDigit(_ u: UInt8) -> Bool { isDigit(u) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66) }
    static func isWordUnit(_ u: UInt8) -> Bool {
        (u >= 0x61 && u <= 0x7A) || (u >= 0x41 && u <= 0x5A) || isDigit(u) || u == 0x5F || u >= 0x80
    }

    static func tokenize(_ text: String) -> [Token] {
        let c = Array(text.utf8)
        var tokens: [Token] = []
        tokens.reserveCapacity(c.count / 3)
        var i = 0
        var lastSignificantIsDot = false
        func next(_ offset: Int = 1) -> UInt8? { i + offset < c.count ? c[i + offset] : nil }
        func emit(_ kind: Kind, from start: Int) {
            if kind == .whitespace {
                tokens.append(Token(kind: kind, value: " ", length: i - start))
                return
            }
            let value = String(decoding: c[start..<i], as: UTF8.self)
            lastSignificantIsDot = value == "."
            tokens.append(Token(kind: kind, value: value, length: i - start))
        }
        let hash = unit("#"), dash = unit("-"), slash = unit("/"), star = unit("*"), single = unit("'"),
            double = unit("\""), backslash = unit("\\"), backtick = unit("`"), openBracket = unit("["),
            closeBracket = unit("]"), open = unit("("), close = unit(")"), question = unit("?"), at = unit("@"),
            colon = unit(":"), dot = unit("."), plus = unit("+"), zero = unit("0"), nUpper = unit("N"),
            nLower = unit("n"), xUpper = unit("X"), xLower = unit("x"), eUpper = unit("E"), eLower = unit("e")

        while i < c.count {
            let start = i, ch = c[i]
            if isWhitespace(ch) {
                while i < c.count && isWhitespace(c[i]) { i += 1 }
                emit(.whitespace, from: start)
            } else if ch == hash || (ch == dash && next() == dash) {
                while i < c.count && !isNewline(c[i]) { i += 1 }
                if i < c.count { i += 1 } // The line break belongs to the comment.
                emit(.lineComment, from: start)
            } else if ch == slash && next() == star {
                i += 2
                while i < c.count && !(c[i] == star && next() == slash) { i += 1 }
                i = min(c.count, i + 2)
                emit(.blockComment, from: start)
            } else if ch == single || ch == double || ((ch == nUpper || ch == nLower) && next() == single) {
                if ch == nUpper || ch == nLower { i += 1 }
                let quote = c[i]
                i += 1
                while i < c.count {
                    if c[i] == backslash { i += 2; continue }
                    if c[i] == quote {
                        if next() == quote { i += 2; continue } // Doubled quote escapes itself.
                        i += 1; break
                    }
                    i += 1
                }
                i = min(i, c.count)
                emit(.string, from: start)
            } else if ch == backtick {
                i += 1
                while i < c.count {
                    if c[i] == backtick { if next() == backtick { i += 2; continue }; i += 1; break }
                    i += 1
                }
                emit(.string, from: start)
            } else if ch == openBracket {
                while i < c.count && c[i] != closeBracket { i += 1 }
                i = min(c.count, i + 1)
                emit(.string, from: start)
            } else if ch == open {
                i += 1; emit(.openParen, from: start)
            } else if ch == close {
                i += 1; emit(.closeParen, from: start)
            } else if ch == question {
                i += 1
                while i < c.count && isDigit(c[i]) { i += 1 }
                emit(.placeholder, from: start)
            } else if (ch == at || ch == colon), let following = next(), isWordUnit(following) {
                i += 1
                while i < c.count && isWordUnit(c[i]) { i += 1 }
                emit(.placeholder, from: start)
            } else if isDigit(ch) {
                if ch == zero, let x = next(), x == xUpper || x == xLower {
                    i += 2
                    while i < c.count && isHexDigit(c[i]) { i += 1 }
                } else {
                    while i < c.count && isDigit(c[i]) { i += 1 }
                    if i < c.count && c[i] == dot, let d = next(), isDigit(d) {
                        i += 1
                        while i < c.count && isDigit(c[i]) { i += 1 }
                    }
                    if i < c.count && (c[i] == eUpper || c[i] == eLower) {
                        var j = i + 1
                        if j < c.count && (c[j] == plus || c[j] == dash) { j += 1 }
                        if j < c.count && isDigit(c[j]) {
                            i = j
                            while i < c.count && isDigit(c[i]) { i += 1 }
                        }
                    }
                }
                emit(.number, from: start)
            } else if isWordUnit(ch) {
                if !lastSignificantIsDot, let (kind, end) = reservedPhrase(in: c, at: i) {
                    i = end; emit(kind, from: start)
                } else {
                    while i < c.count && isWordUnit(c[i]) { i += 1 }
                    emit(.word, from: start)
                }
            } else {
                let rest = String(decoding: c[i..<min(c.count, i + 3)], as: UTF8.self)
                let length = operators.first(where: { rest.hasPrefix($0) })?.utf8.count ?? 1
                i += length
                emit(.op, from: start)
            }
        }
        return tokens
    }

    /// The longest keyword phrase (up to three words, any whitespace between) starting at `start`.
    private static func reservedPhrase(in c: [UInt8], at start: Int) -> (Kind, Int)? {
        var end = start
        while end < c.count && isWordUnit(c[end]) { end += 1 }
        guard end - start <= longestKeyword else { return nil }
        let first = String(decoding: c[start..<end], as: UTF8.self).uppercased()
        // Most words can't start a multi-word keyword: one lookup, no further words read.
        guard multiWordStarts.contains(first) else { return phrases[first].map { ($0, end) } }
        var words: [(String, Int)] = []
        var i = start
        while words.count < 3 {
            let wordStart = i
            while i < c.count && isWordUnit(c[i]) { i += 1 }
            guard i > wordStart, i - wordStart <= longestKeyword else { break }
            words.append((String(decoding: c[wordStart..<i], as: UTF8.self).uppercased(), i))
            var j = i
            while j < c.count && isWhitespace(c[j]) { j += 1 }
            guard j > i, j < c.count, isWordUnit(c[j]) else { break }
            i = j
        }
        for count in stride(from: words.count, through: 1, by: -1) {
            let phrase = words.prefix(count).map(\.0).joined(separator: " ")
            if let kind = phrases[phrase] { return (kind, words[count - 1].1) }
        }
        return nil
    }

    /// First words of multi-word keywords (GROUP BY, LEFT OUTER JOIN, ON UPDATE, ...).
    private static let multiWordStarts = Set(phrases.keys.filter { $0.contains(" ") }.compactMap { $0.split(separator: " ").first.map(String.init) })

    /// No keyword is longer than this, so longer words are identifiers without a table lookup.
    private static let longestKeyword = phrases.keys.flatMap { $0.split(separator: " ") }.map(\.count).max() ?? 0

    // MARK: Formatter

    static func format(_ text: String, options: Options = Options()) -> String {
        var formatter = Layout(tokens: tokenize(text), options: options)
        return formatter.run()
    }

    /// Builds the output in a UTF-8 byte buffer: appends and "does it end with a space/newline?"
    /// checks are then O(1) byte operations rather than String/Character work.
    private struct Layout {
        let tokens: [Token]
        let options: Options
        var output: [UInt8] = []
        var indentTypes: [Bool] = [] // true = top-level indent, false = block (parenthesis) indent
        var inlineLevel = 0
        var previousReservedIsLimit = false
        var index = 0
        let indentBytes: [UInt8]

        init(tokens: [Token], options: Options) {
            self.tokens = tokens
            self.options = options
            indentBytes = Array(options.indent.utf8)
            output.reserveCapacity(tokens.reduce(0) { $0 + $1.length } * 3 / 2)
        }

        mutating func append(_ text: String) { output.append(contentsOf: text.utf8) }
        mutating func append(_ byte: UInt8) { output.append(byte) }

        mutating func noteReserved(_ token: Token) {
            previousReservedIsLimit = token.value.utf8.count == 5 && token.value.uppercased() == "LIMIT"
        }

        mutating func run() -> String {
            for (position, token) in tokens.enumerated() {
                index = position
                switch token.kind {
                case .whitespace: break // Whitespace is re-created below.
                case .lineComment: append(token.value); addNewline()
                case .blockComment:
                    addNewline(); append(indentComment(token.value)); addNewline()
                case .topLevel:
                    decreaseTopLevel(); addNewline(); indentTypes.append(true)
                    append(keyword(token.value)); addNewline(); noteReserved(token)
                case .topLevelNoIndent:
                    decreaseTopLevel(); addNewline(); append(keyword(token.value)); addNewline(); noteReserved(token)
                case .newline:
                    addNewline(); append(keyword(token.value)); append(0x20); noteReserved(token)
                case .reserved:
                    append(keyword(token.value)); append(0x20); noteReserved(token)
                case .openParen: openParenthesis(token)
                case .closeParen: closeParenthesis(token)
                case .placeholder, .string, .number, .word: append(token.value); append(0x20)
                case .op:
                    switch token.value {
                    case ",":
                        trimEnd(); append(0x2C); append(0x20)
                        if inlineLevel == 0 && !previousReservedIsLimit { addNewline() }
                    case ":": trimEnd(); append(0x3A); append(0x20)
                    case ".": trimEnd(); append(0x2E)
                    case ";":
                        indentTypes.removeAll()
                        trimEnd(); append(0x3B)
                        for _ in 0..<max(1, options.linesBetweenQueries) { append(0x0A) }
                    default: append(token.value); append(0x20)
                    }
                }
            }
            // Trim leading and trailing whitespace on the bytes, then make the String once.
            var first = 0, last = output.count
            while first < last && Self.isSpaceOrNewline(output[first]) { first += 1 }
            while last > first && Self.isSpaceOrNewline(output[last - 1]) { last -= 1 }
            return String(decoding: output[first..<last], as: UTF8.self)
        }

        static func isSpaceOrNewline(_ byte: UInt8) -> Bool { byte == 0x20 || (0x09...0x0D).contains(byte) }

        func keyword(_ value: String) -> String {
            // Multi-word keywords may contain runs of whitespace or newlines: collapse them to one space.
            let collapsed = value.utf8.contains(where: Self.isSpaceOrNewline)
                ? value.split(whereSeparator: \.isWhitespace).joined(separator: " ") : value
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
            if previous != .whitespace && previous != .openParen && previous != .lineComment { trimEnd() }
            append(options.uppercase ? token.value.uppercased() : token.value)
            if inlineLevel > 0 { inlineLevel += 1 }
            else if isInlineBlock(from: index) { inlineLevel = 1 }
            if inlineLevel == 0 { indentTypes.append(false); addNewline() }
        }

        mutating func closeParenthesis(_ token: Token) {
            let value = options.uppercase ? token.value.uppercased() : token.value
            if inlineLevel > 0 {
                inlineLevel -= 1
                trimEnd(); append(value); append(0x20)
            } else {
                while let type = indentTypes.popLast(), type {} // Drop top-level indents inside the block too.
                addNewline(); append(value); append(0x20)
            }
        }

        func isInlineBlock(from start: Int) -> Bool {
            var length = 0, level = 0
            for token in tokens[start...] {
                length += token.length
                if length > inlineMaxLength { return false }
                switch token.kind {
                case .openParen: level += 1
                case .closeParen:
                    level -= 1
                    if level == 0 { return true }
                case .topLevel, .newline, .lineComment, .blockComment: return false
                default: if token.value == ";" { return false }
                }
            }
            return false
        }

        mutating func decreaseTopLevel() { if indentTypes.last == true { indentTypes.removeLast() } }

        mutating func trimEnd() {
            while let last = output.last, last == 0x20 || last == 0x09 { output.removeLast() }
        }

        mutating func addNewline() {
            trimEnd()
            if output.last != 0x0A { output.append(0x0A) }
            for _ in 0..<indentTypes.count { output.append(contentsOf: indentBytes) }
        }
    }
}
