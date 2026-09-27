import Foundation

struct LexerState: Equatable, Sendable {
    var blockDepth = 0
    var markupComment = false
    var inTag = false
    var tagNameSeen = false
    var quote: [UInt16] = []
    var fencedCode = false
}

/// A deliberately lexical highlighter, with state carried across logical lines.
struct LineLexer: Sendable {
    let language: SyntaxLanguage
    private let keywords: Set<String>
    // Language traits, worked out once: they're consulted for nearly every character.
    private let isMarkup, hasSlashComments, hasBlockComments, nestsBlockComments: Bool
    private let isSQL, isYAML, isJSON, hasTripleQuotes, namesKeysAsKeywords: Bool

    init(language: SyntaxLanguage) {
        self.language = language
        keywords = language.keywords
        isMarkup = language.isMarkup
        hasSlashComments = language.hasSlashComments
        hasBlockComments = language.hasBlockComments
        nestsBlockComments = language == .swift
        isSQL = language == .sql
        isYAML = language == .yaml
        isJSON = language == .json
        hasTripleQuotes = language == .swift || language == .java
        namesKeysAsKeywords = language == .yaml || language == .css
    }

    private static let markupCommentOpen = Array("<!--".utf16), markupCommentClose = Array("-->".utf16)
    private static let blockOpen = Array("/*".utf16), blockClose = Array("*/".utf16)
    private static let lineComment = Array("//".utf16), sqlComment = Array("--".utf16)
    private static let tripleQuote = Array("\"\"\"".utf16), fence = Array("```".utf16)
    private static let punctuation: [Bool] = {
        var table = [Bool](repeating: false, count: 128)
        for unit in "{}[]():;,=.+-*/<>!&|?@#$%_~".utf16 { table[Int(unit)] = true }
        return table
    }()
    private static let literals: Set<String> = ["true", "false", "null", "nil", "undefined", "yes", "no"]

    func scan(_ line: String, state: inout LexerState) -> [SyntaxToken] {
        scan(Array(line.utf16), state: &state)
    }

    /// Scans one line (with its terminator, if any). Token ranges are offsets into `units`. With
    /// `collect` false only the state is advanced, which is all that's needed to reach a later line.
    func scan(_ units: [UInt16], state: inout LexerState, collect: Bool = true) -> [SyntaxToken] {
        guard language != .plain else { return [] }
        var tokens: [SyntaxToken] = []
        var i = 0
        func matches(_ pattern: [UInt16], at offset: Int) -> Bool {
            guard offset + pattern.count <= units.count else { return false }
            for k in 0..<pattern.count where units[offset + k] != pattern[k] { return false }
            return true
        }
        func emit(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
            if collect && end > start { tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind)) }
        }
        if language == .markdown {
            var first = 0
            while first < units.count && (units[first] == 32 || units[first] == 9) { first += 1 }
            if matches(Self.fence, at: first) {
                state.fencedCode.toggle()
                emit(0, units.count, .punctuation)
                return tokens
            }
            if state.fencedCode { emit(0, units.count, .string); return tokens }
            if first < units.count && units[first] == 35 { emit(0, units.count, .heading); return tokens }
        }
        while i < units.count {
            let start = i
            if state.markupComment {
                while i < units.count && !matches(Self.markupCommentClose, at: i) { i += 1 }
                if i < units.count { i += 3; state.markupComment = false }
                emit(start, i, .comment)
            } else if state.blockDepth > 0 {
                while i < units.count {
                    if matches(Self.blockClose, at: i) {
                        state.blockDepth -= 1; i += 2
                        if state.blockDepth == 0 { break }
                    } else if nestsBlockComments && matches(Self.blockOpen, at: i) {
                        state.blockDepth += 1; i += 2
                    } else { i += 1 }
                }
                emit(start, i, .comment)
            } else if !state.quote.isEmpty {
                let delimiter = state.quote
                while i < units.count {
                    if matches(delimiter, at: i) {
                        i += delimiter.count
                        // SQL doubles quote characters to escape them.
                        if isSQL && i < units.count && units[i] == delimiter[0] { i += 1; continue }
                        state.quote = []
                        break
                    }
                    if units[i] == 92 && !isMarkup { i = min(units.count, i + 2) }
                    else { i += 1 }
                }
                emit(start, i, .string)
            } else if units[i] == 32 || units[i] == 9 {
                i += 1 // Spaces and tabs between tokens.
            } else if isMarkup && matches(Self.markupCommentOpen, at: i) {
                state.markupComment = true
                i += 4
                emit(start, i, .comment)
            } else if hasBlockComments && matches(Self.blockOpen, at: i) {
                state.blockDepth = 1; i += 2; emit(start, i, .comment)
            } else if (hasSlashComments && matches(Self.lineComment, at: i)) ||
                        (isSQL && matches(Self.sqlComment, at: i)) ||
                        (isYAML && units[i] == 35 && (i == 0 || units[i - 1] == 32 || units[i - 1] == 9)) {
                emit(i, units.count, .comment); i = units.count
            } else if isJSON && units[i] == 34 {
                // A JSON string followed by a colon is a property name; Notepad++ colours those differently.
                i += 1
                var closed = false
                while i < units.count {
                    if units[i] == 92 { i = min(units.count, i + 2); continue }
                    if units[i] == 34 { i += 1; closed = true; break }
                    if units[i] == 10 || units[i] == 13 { break }
                    i += 1
                }
                var next = i
                while next < units.count && (units[next] == 32 || units[next] == 9) { next += 1 }
                emit(start, i, closed && next < units.count && units[next] == 58 ? .property : .string)
            } else if opensString(units, at: i, state: state) {
                if hasTripleQuotes && matches(Self.tripleQuote, at: i) {
                    state.quote = Self.tripleQuote; i += 3
                } else { state.quote = [units[i]]; i += 1 }
                emit(start, i, .string)
            } else if isMarkup && units[i] == 60 {
                state.inTag = true; state.tagNameSeen = false; i += 1; emit(start, i, .punctuation)
            } else if isMarkup && units[i] == 62 {
                state.inTag = false; i += 1; emit(start, i, .punctuation)
            } else if units[i] >= 48 && units[i] <= 57 {
                i += 1
                while i < units.count && ((units[i] >= 48 && units[i] <= 57) || units[i] == 46 || units[i] == 95) { i += 1 }
                emit(start, i, .number)
            } else if Self.isWord(units[i]) {
                i += 1
                while i < units.count && (Self.isWord(units[i]) || (units[i] >= 48 && units[i] <= 57)) { i += 1 }
                // Only words that could be a literal or keyword become Strings.
                guard !keywords.isEmpty || isMarkup || namesKeysAsKeywords || (2...9).contains(i - start) else { continue }
                let word = String(decoding: units[start..<i], as: UTF16.self)
                let normalized = isSQL ? word.lowercased() : word
                if Self.literals.contains(normalized) {
                    emit(start, i, .literal)
                } else if keywords.contains(normalized) { emit(start, i, .keyword) }
                else if isMarkup && state.inTag {
                    // Notepad++ colours the tag name and its attribute names differently.
                    emit(start, i, state.tagNameSeen ? .attribute : .tag)
                    state.tagNameSeen = true
                }
                else if namesKeysAsKeywords {
                    var next = i
                    while next < units.count && units[next] == 32 { next += 1 }
                    if next < units.count && units[next] == 58 { emit(start, i, .keyword) }
                }
            } else {
                if units[i] < 128 && Self.punctuation[Int(units[i])] { emit(i, i + 1, .punctuation) }
                i += 1
            }
        }
        // Normal single-line strings recover at EOL; multiline literals retain state.
        if state.quote.count == 1 && state.quote[0] != 96 && !isMarkup && !isSQL && !isYAML { state.quote = [] }
        return tokens
    }

    /// Where a quote character starts a string. Prose apostrophes ("don't") must not open strings in
    /// markup text, Markdown or unquoted YAML scalars, where the quote state can carry across lines.
    private func opensString(_ units: [UInt16], at i: Int, state: LexerState) -> Bool {
        let unit = units[i]
        switch language {
        case .json: return unit == 34
        case .markdown: return unit == 96
        case .xml, .html: return state.inTag && (unit == 34 || unit == 39)
        case .yaml:
            guard unit == 34 || unit == 39 else { return false }
            // A quoted scalar begins a value: at line start or after `:`, `-`, `?`, `,`, `[` or `{`.
            var j = i - 1
            while j >= 0 && (units[j] == 32 || units[j] == 9) { j -= 1 }
            return j < 0 || [58, 45, 63, 44, 91, 123].contains(units[j])
        case .javascript, .typescript: return unit == 34 || unit == 39 || unit == 96
        default: return unit == 34 || unit == 39
        }
    }

    private static func isWord(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit > 127
    }
}
