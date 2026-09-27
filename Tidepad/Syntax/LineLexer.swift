import Foundation

struct LexerState: Equatable, Sendable {
    var blockDepth = 0
    var markupComment = false
    var inTag = false
    var quote: [UInt16] = []
    var fencedCode = false
}

/// A deliberately lexical highlighter, with state carried across logical lines.
struct LineLexer: Sendable {
    let language: SyntaxLanguage
    private let keywords: Set<String>
    init(language: SyntaxLanguage) {
        self.language = language
        keywords = language.keywords
    }

    func scan(_ line: String, state: inout LexerState) -> [SyntaxToken] {
        guard language != .plain else { return [] }
        let units = Array(line.utf16)
        var tokens: [SyntaxToken] = []
        var i = 0
        func matches(_ text: String, at offset: Int) -> Bool {
            let pattern = Array(text.utf16)
            return offset + pattern.count <= units.count && Array(units[offset..<(offset + pattern.count)]) == pattern
        }
        func emit(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
            if end > start { tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind)) }
        }
        if language == .markdown {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                state.fencedCode.toggle()
                emit(0, units.count, .punctuation)
                return tokens
            }
            if state.fencedCode { emit(0, units.count, .string); return tokens }
            if trimmed.hasPrefix("#") { emit(0, units.count, .heading); return tokens }
        }
        while i < units.count {
            let start = i
            if state.markupComment {
                while i < units.count && !matches("-->", at: i) { i += 1 }
                if i < units.count { i += 3; state.markupComment = false }
                emit(start, i, .comment)
            } else if state.blockDepth > 0 {
                while i < units.count {
                    if matches("*/", at: i) {
                        state.blockDepth -= 1; i += 2
                        if state.blockDepth == 0 { break }
                    } else if language == .swift && matches("/*", at: i) {
                        state.blockDepth += 1; i += 2
                    } else { i += 1 }
                }
                emit(start, i, .comment)
            } else if !state.quote.isEmpty {
                let delimiter = state.quote
                while i < units.count {
                    if i + delimiter.count <= units.count && Array(units[i..<(i + delimiter.count)]) == delimiter {
                        i += delimiter.count
                        // SQL doubles quote characters to escape them.
                        if language == .sql && i < units.count && units[i] == delimiter[0] { i += 1; continue }
                        state.quote = []
                        break
                    }
                    if units[i] == 92 && !language.isMarkup { i = min(units.count, i + 2) }
                    else { i += 1 }
                }
                emit(start, i, .string)
            } else if language.isMarkup && matches("<!--", at: i) {
                state.markupComment = true
                i += 4
                emit(start, i, .comment)
            } else if language.hasBlockComments && matches("/*", at: i) {
                state.blockDepth = 1; i += 2; emit(start, i, .comment)
            } else if (language.hasSlashComments && matches("//", at: i)) ||
                        (language == .sql && matches("--", at: i)) ||
                        (language == .yaml && units[i] == 35 && (i == 0 || units[i - 1] == 32 || units[i - 1] == 9)) {
                emit(i, units.count, .comment); i = units.count
            } else if units[i] == 34 || (units[i] == 39 && language != .json) ||
                        (units[i] == 96 && [.javascript, .typescript, .markdown].contains(language)) {
                if matches("\"\"\"", at: i) && [.swift, .java].contains(language) {
                    state.quote = [34, 34, 34]; i += 3
                } else { state.quote = [units[i]]; i += 1 }
                emit(start, i, .string)
            } else if language.isMarkup && units[i] == 60 {
                state.inTag = true; i += 1; emit(start, i, .punctuation)
            } else if language.isMarkup && units[i] == 62 {
                state.inTag = false; i += 1; emit(start, i, .punctuation)
            } else if units[i] >= 48 && units[i] <= 57 {
                i += 1
                while i < units.count && ((units[i] >= 48 && units[i] <= 57) || [46, 95].contains(units[i])) { i += 1 }
                emit(start, i, .number)
            } else if Self.isWord(units[i]) {
                i += 1
                while i < units.count && (Self.isWord(units[i]) || (units[i] >= 48 && units[i] <= 57)) { i += 1 }
                let word = String(decoding: units[start..<i], as: UTF16.self)
                let normalized = language == .sql ? word.lowercased() : word
                if ["true", "false", "null", "nil", "undefined", "yes", "no"].contains(normalized) {
                    emit(start, i, .literal)
                } else if keywords.contains(normalized) { emit(start, i, .keyword) }
                else if language.isMarkup && state.inTag { emit(start, i, .tag) }
                else if language == .yaml || language == .css {
                    var next = i
                    while next < units.count && units[next] == 32 { next += 1 }
                    if next < units.count && units[next] == 58 { emit(start, i, .keyword) }
                }
            } else {
                if "{}[]():;,=.+-*/<>!&|?@#$%_~".utf16.contains(units[i]) { emit(i, i + 1, .punctuation) }
                i += 1
            }
        }
        // Normal single-line strings recover at EOL; multiline literals retain state.
        if state.quote.count == 1 && state.quote[0] != 96 && !language.isMarkup && language != .sql && language != .yaml { state.quote = [] }
        return tokens
    }

    private static func isWord(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit > 127
    }
}
