import Foundation

struct SyntaxLine: Sendable {
    let text: String
    let incoming: LexerState
    let outgoing: LexerState
    let tokens: [SyntaxToken]
}

struct IncrementalSyntaxEngine: Sendable {
    private(set) var language = SyntaxLanguage.plain
    private(set) var lines: [SyntaxLine] = []
    private(set) var starts: [Int] = []
    private(set) var scannedLineCount = 0

    mutating func update(text: String, language: SyntaxLanguage) {
        let source = text as NSString
        var newLines: [String] = []
        var newStarts: [Int] = []
        var offset = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            newStarts.append(offset)
            newLines.append(source.substring(with: range))
            offset = NSMaxRange(range)
        }
        var prefix = 0
        if self.language == language {
            while prefix < min(lines.count, newLines.count) && lines[prefix].text == newLines[prefix] { prefix += 1 }
        }
        var suffix = 0
        if self.language == language {
            while suffix < min(lines.count, newLines.count) - prefix &&
                    lines[lines.count - suffix - 1].text == newLines[newLines.count - suffix - 1] { suffix += 1 }
        }
        let lexer = LineLexer(language: language)
        var updated = Array(lines.prefix(prefix))
        var state = updated.last?.outgoing ?? LexerState()
        scannedLineCount = 0
        for position in prefix..<newLines.count {
            if Task.isCancelled { return }
            let oldPosition = lines.count - (newLines.count - position)
            if position >= newLines.count - suffix, oldPosition >= 0, lines[oldPosition].incoming == state {
                updated.append(contentsOf: lines[oldPosition...])
                break
            }
            let incoming = state
            let tokens = lexer.scan(newLines[position], state: &state)
            updated.append(SyntaxLine(text: newLines[position], incoming: incoming, outgoing: state, tokens: tokens))
            scannedLineCount += 1
        }
        self.language = language
        lines = updated
        starts = newStarts
    }

    func tokens(in range: NSRange) -> [SyntaxToken] {
        guard !starts.isEmpty, range.length > 0 else { return [] }
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= range.location { low = middle + 1 } else { high = middle }
        }
        var result: [SyntaxToken] = []
        for line in max(0, low - 1)..<lines.count {
            let offset = starts[line]
            if offset >= NSMaxRange(range) { break }
            for token in lines[line].tokens {
                let absolute = NSRange(location: token.range.location + offset, length: token.range.length)
                let clipped = NSIntersectionRange(absolute, range)
                if clipped.length > 0 { result.append(SyntaxToken(range: clipped, kind: token.kind)) }
            }
        }
        return result
    }
}
