import Foundation

/// What the lexer remembers from one line to the next: an open block comment, markup comment, tag,
/// string or fenced code block. A plain value, so saving it at checkpoints costs nothing.
struct LexerState: Equatable, Sendable {
    var blockDepth = 0
    var markupComment = false
    var inTag = false
    var tagNameSeen = false
    /// The quote character of an open string (0: none), and whether it opened with """.
    var quote: UInt8 = 0
    var tripleQuote = false
    var fencedCode = false
}

/// A deliberately lexical highlighter, with state carried across logical lines.
///
/// It reads UTF-16 (the normal editor's text, and the lines the large-file view draws) or UTF-8 (the
/// large file's own bytes, for the background pass): everything it looks for is ASCII, and a
/// non-ASCII character is part of a word either way, so both give the same tokens and states. Token
/// offsets are in the units given. Nothing is allocated per character or per word: keywords are
/// matched in place against tables by length and first letter.
struct LineLexer: Sendable {
    let language: SyntaxLanguage
    // Language traits, worked out once: they're consulted for nearly every character.
    private let isMarkup, hasSlashComments, hasBlockComments, nestsBlockComments: Bool
    private let isSQL, isYAML, isJSON, isMarkdown, isPython, hasTripleQuotes, namesKeysAsKeywords, hasKeywords: Bool
    /// true/false/null/yes/no are values in code and data, but ordinary words in prose (Markdown) and
    /// in markup text.
    private let hasLiterals: Bool
    /// Keywords and literals as ASCII, at [length * 128 + first letter] (lower case in SQL, which ignores case).
    private let keywordTable: [[[UInt8]]]
    private let literalTable: [[[UInt8]]]
    /// Characters that can open something that lasts past the line (a string, comment or tag).
    private let opensState: [Bool]

    private static let longestWord = 16
    private static let literals = ["true", "false", "null", "nil", "undefined", "yes", "no"]
    private static let punctuation: [Bool] = {
        var table = [Bool](repeating: false, count: 128)
        for unit in "{}[]():;,=.+-*/<>!&|?@#$%_~".utf8 { table[Int(unit)] = true }
        return table
    }()

    init(language: SyntaxLanguage) {
        self.language = language
        isMarkup = language.isMarkup
        hasSlashComments = language.hasSlashComments
        hasBlockComments = language.hasBlockComments
        nestsBlockComments = language == .swift
        isSQL = language == .sql
        isYAML = language == .yaml
        isJSON = language == .json
        isMarkdown = language == .markdown
        isPython = language == .python
        hasTripleQuotes = language == .swift || language == .java
        namesKeysAsKeywords = language == .yaml || language == .css
        hasLiterals = !language.isMarkup && language != .markdown
        let keywords = language.keywords
        hasKeywords = !keywords.isEmpty
        func table(_ words: [String]) -> [[[UInt8]]] {
            var table = [[[UInt8]]](repeating: [], count: (Self.longestWord + 1) * 128)
            for word in words {
                let bytes = Array(word.utf8)
                guard (1...Self.longestWord).contains(bytes.count), bytes.allSatisfy({ $0 < 128 }) else { continue }
                table[bytes.count * 128 + Int(bytes[0])].append(bytes)
            }
            return table
        }
        keywordTable = table(Array(keywords))
        literalTable = table(Self.literals)
        var opens = [Bool](repeating: false, count: 256)
        for byte in "\"'`/<>".utf8 { opens[Int(byte)] = true }
        opensState = opens
    }

    func scan(_ line: String, state: inout LexerState) -> [SyntaxToken] {
        scan(Array(line.utf16), state: &state)
    }

    /// Scans one line of UTF-16 (with its terminator, if any). Token ranges are offsets into `units`.
    /// With `collect` false only the state is advanced, which is all that's needed to reach a later line.
    func scan(_ units: [UInt16], state: inout LexerState, collect: Bool = true) -> [SyntaxToken] {
        units.withUnsafeBufferPointer { lex($0, state: &state, collect: collect) }
    }

    /// Scans one line of UTF-8 bytes; token ranges are byte offsets.
    func scan(utf8 bytes: UnsafeBufferPointer<UInt8>, state: inout LexerState, collect: Bool = true) -> [SyntaxToken] {
        lex(bytes, state: &state, collect: collect)
    }

    // One implementation for both widths; the two entry points above are in this file, so each is
    // compiled for its own width.
    @inline(__always)
    private func lex<Unit: FixedWidthInteger & UnsignedInteger>(_ units: UnsafeBufferPointer<Unit>, state: inout LexerState,
                                                                 collect: Bool) -> [SyntaxToken] {
        guard language != .plain else { return [] }
        let count = units.count
        @inline(__always) func at(_ k: Int) -> UInt32 { UInt32(truncatingIfNeeded: units[k]) }
        @inline(__always) func pair(_ k: Int, _ a: UInt32, _ b: UInt32) -> Bool { k + 1 < count && at(k) == a && at(k + 1) == b }
        @inline(__always) func three(_ k: Int, _ a: UInt32, _ b: UInt32, _ c: UInt32) -> Bool {
            k + 2 < count && at(k) == a && at(k + 1) == b && at(k + 2) == c
        }
        @inline(__always) func isWord(_ unit: UInt32) -> Bool { (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit > 127 }
        @inline(__always) func isDigit(_ unit: UInt32) -> Bool { unit >= 48 && unit <= 57 }

        // Only following the state: a line with nothing that opens a string, comment or tag, starting
        // with nothing open, leaves the state as it was.
        if !collect && state == LexerState() {
            var k = 0
            while k < count && !(at(k) < 256 && opensState[Int(at(k))]) { k += 1 }
            if k == count { return [] }
        }

        var tokens: [SyntaxToken] = []
        @inline(__always) func emit(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
            if collect && end > start { tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind)) }
        }
        /// Whether units[start..<end] is in a table (folding ASCII case in SQL).
        func listed(_ table: [[[UInt8]]], _ start: Int, _ end: Int) -> Bool {
            let length = end - start
            guard length <= Self.longestWord else { return false }
            @inline(__always) func folded(_ k: Int) -> UInt32 {
                let unit = at(k)
                return isSQL && unit >= 65 && unit <= 90 ? unit + 32 : unit
            }
            let first = folded(start)
            guard first < 128 else { return false }
            for word in table[length * 128 + Int(first)] {
                var k = 1
                while k < length && folded(start + k) == UInt32(word[k]) { k += 1 }
                if k == length { return true }
            }
            return false
        }

        if isMarkdown {
            var first = 0
            while first < count && (at(first) == 32 || at(first) == 9) { first += 1 }
            if three(first, 96, 96, 96) {
                state.fencedCode.toggle()
                emit(0, count, .punctuation)
                return tokens
            }
            if state.fencedCode { emit(0, count, .string); return tokens }
            if first < count && at(first) == 35 { emit(0, count, .heading); return tokens }
        }
        var i = 0
        while i < count {
            let start = i
            let unit = at(i)
            if state.markupComment {
                while i < count && !three(i, 45, 45, 62) { i += 1 } // -->
                if i < count { i += 3; state.markupComment = false }
                emit(start, i, .comment)
            } else if state.blockDepth > 0 {
                while i < count {
                    if pair(i, 42, 47) { // */
                        state.blockDepth -= 1; i += 2
                        if state.blockDepth == 0 { break }
                    } else if nestsBlockComments && pair(i, 47, 42) {
                        state.blockDepth += 1; i += 2
                    } else { i += 1 }
                }
                emit(start, i, .comment)
            } else if state.quote != 0 {
                let quote = UInt32(state.quote), triple = state.tripleQuote
                while i < count {
                    if triple ? three(i, quote, quote, quote) : at(i) == quote {
                        i += triple ? 3 : 1
                        // SQL doubles quote characters to escape them.
                        if isSQL && i < count && at(i) == quote { i += 1; continue }
                        state.quote = 0
                        state.tripleQuote = false
                        break
                    }
                    // A backslash escapes the next character, except in YAML single quotes ('' escapes a
                    // quote there, so 'C:\' ends at its quote) and Markdown code spans.
                    if at(i) == 92 && !isMarkup && !isMarkdown && !(isYAML && quote == 39) { i = min(count, i + 2) }
                    else { i += 1 }
                }
                emit(start, i, .string)
            } else if unit == 32 || unit == 9 {
                i += 1 // Spaces and tabs between tokens.
            } else if isMarkup && unit == 60 && i + 3 < count && at(i + 1) == 33 && at(i + 2) == 45 && at(i + 3) == 45 { // <!--
                state.markupComment = true
                i += 4
                emit(start, i, .comment)
            } else if hasBlockComments && pair(i, 47, 42) { // /*
                state.blockDepth = 1; i += 2; emit(start, i, .comment)
            } else if (hasSlashComments && pair(i, 47, 47)) ||
                        (isSQL && pair(i, 45, 45)) ||
                        (isPython && unit == 35) ||
                        (isYAML && unit == 35 && (i == 0 || at(i - 1) == 32 || at(i - 1) == 9)) {
                emit(i, count, .comment); i = count
            } else if isJSON && unit == 34 {
                // A JSON string followed by a colon is a property name; Notepad++ colours those differently.
                i += 1
                var closed = false
                while i < count {
                    if at(i) == 92 { i = min(count, i + 2); continue }
                    if at(i) == 34 { i += 1; closed = true; break }
                    if at(i) == 10 || at(i) == 13 { break }
                    i += 1
                }
                var next = i
                while next < count && (at(next) == 32 || at(next) == 9) { next += 1 }
                emit(start, i, closed && next < count && at(next) == 58 ? .property : .string)
            } else if opensString(unit, at: i, state: state, previous: { at($0) }) {
                // Swift and Java have """ strings; Python has both """ and '''.
                if (hasTripleQuotes && three(i, 34, 34, 34)) || (isPython && three(i, unit, unit, unit)) {
                    state.quote = UInt8(unit); state.tripleQuote = true; i += 3
                } else { state.quote = UInt8(unit); i += 1 }
                emit(start, i, .string)
            } else if isMarkup && unit == 60 {
                state.inTag = true; state.tagNameSeen = false; i += 1; emit(start, i, .punctuation)
            } else if isMarkup && unit == 62 {
                state.inTag = false; i += 1; emit(start, i, .punctuation)
            } else if isDigit(unit) {
                i += 1
                while i < count && (isDigit(at(i)) || at(i) == 46 || at(i) == 95) { i += 1 }
                emit(start, i, .number)
            } else if isWord(unit) {
                i += 1
                while i < count && (isWord(at(i)) || isDigit(at(i))) { i += 1 }
                // Only words that could be a literal or keyword are looked up.
                guard hasKeywords || isMarkup || namesKeysAsKeywords || (hasLiterals && (2...9).contains(i - start)) else { continue }
                if hasLiterals && listed(literalTable, start, i) {
                    emit(start, i, .literal)
                } else if hasKeywords && listed(keywordTable, start, i) { emit(start, i, .keyword) }
                else if isMarkup && state.inTag {
                    // Notepad++ colours the tag name and its attribute names differently.
                    emit(start, i, state.tagNameSeen ? .attribute : .tag)
                    state.tagNameSeen = true
                }
                else if namesKeysAsKeywords {
                    var next = i
                    while next < count && at(next) == 32 { next += 1 }
                    if next < count && at(next) == 58 { emit(start, i, .keyword) }
                }
            } else {
                if unit < 128 && Self.punctuation[Int(unit)] { emit(i, i + 1, .punctuation) }
                i += 1
            }
        }
        // Normal single-line strings recover at EOL; multiline literals retain state.
        // (JavaScript template literals in backquotes can span lines; Markdown code spans don't carry
        // on past their line, so a stray backquote doesn't colour the rest of the file.)
        if state.quote != 0 && !state.tripleQuote && (isMarkdown || (state.quote != 96 && !isMarkup && !isSQL && !isYAML)) { state.quote = 0 }
        return tokens
    }

    /// Where a quote character starts a string. Prose apostrophes ("don't") must not open strings in
    /// markup text, Markdown or unquoted YAML scalars, where the quote state can carry across lines.
    @inline(__always)
    private func opensString(_ unit: UInt32, at i: Int, state: LexerState, previous: (Int) -> UInt32) -> Bool {
        switch language {
        case .json: return unit == 34
        case .markdown: return unit == 96
        case .xml, .html: return state.inTag && (unit == 34 || unit == 39)
        case .yaml:
            guard unit == 34 || unit == 39 else { return false }
            // A quoted scalar begins a value: at line start or after `:`, `-`, `?`, `,`, `[` or `{`.
            var j = i - 1
            while j >= 0 && (previous(j) == 32 || previous(j) == 9) { j -= 1 }
            return j < 0 || [58, 45, 63, 44, 91, 123].contains(previous(j))
        case .javascript, .typescript: return unit == 34 || unit == 39 || unit == 96
        default: return unit == 34 || unit == 39
        }
    }
}
