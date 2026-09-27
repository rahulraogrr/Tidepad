import Foundation

/// Lazy, Scintilla-style colouring. The lexer's state is recorded at the start of every
/// `checkpointStride`-th line, and lines are lexed only as far as someone asks for tokens — normally
/// the end of the visible text. An edit discards the recorded states after the edited line, so the next
/// request re-lexes from there to the viewport and no further. Nothing is kept per token: visible lines
/// are re-lexed from the nearest checkpoint each time, which costs at most `checkpointStride` lines.
///
/// Lines come from the editor's `LineIndex`, which is already kept up to date incrementally.
struct IncrementalSyntaxEngine: Sendable {
    static let checkpointStride = 32

    private(set) var language: SyntaxLanguage
    private var lexer: LineLexer
    /// `checkpoints[k]` is the lexer state at the start of line `k * checkpointStride`.
    private var checkpoints = [LexerState()]
    /// Lines longer than this are left uncoloured (and don't change the state), so one enormous line —
    /// minified JSON, say — can't stall the editor.
    var maximumLineLength = 100_000
    /// Lines lexed so far, for checks and measurements.
    private(set) var scannedLineCount = 0

    init(language: SyntaxLanguage = .plain) {
        self.language = language
        lexer = LineLexer(language: language)
    }

    /// Lines whose starting state is known without lexing.
    var knownLineCount: Int { (checkpoints.count - 1) * Self.checkpointStride + 1 }

    mutating func setLanguage(_ language: SyntaxLanguage) {
        guard language != self.language else { return }
        self.language = language
        lexer = LineLexer(language: language)
        checkpoints = [LexerState()]
    }

    /// Call after an edit that changed `line` (in the updated line numbering). States at the start of
    /// `line` and the lines before it are still valid; everything after may have changed.
    mutating func invalidate(fromLine line: Int) {
        let keep = max(0, line) / Self.checkpointStride + 1
        if checkpoints.count > keep { checkpoints.removeSubrange(keep...) }
    }

    mutating func invalidateAll() { checkpoints = [LexerState()] }

    /// Tokens overlapping `range`, in document offsets and clipped to it.
    mutating func tokens(in range: NSRange, index: LineIndex, text: NSString) -> [SyntaxToken] {
        guard language != .plain, range.length > 0, range.location < text.length else { return [] }
        let first = index.line(at: range.location)
        let last = index.line(at: min(text.length, NSMaxRange(range)) - 1)
        var state = startState(ofLine: first, index: index, text: text)
        var result: [SyntaxToken] = []
        for line in first...last {
            let lineRange = self.lineRange(line, index: index, text: text)
            for token in scan(line, lineRange, text: text, state: &state) {
                let absolute = NSRange(location: token.range.location + lineRange.location, length: token.range.length)
                let clipped = NSIntersectionRange(absolute, range)
                if clipped.length > 0 { result.append(SyntaxToken(range: clipped, kind: token.kind)) }
            }
        }
        return result
    }

    /// The lexer state at the start of `line`, lexing forward from the nearest checkpoint.
    mutating func startState(ofLine line: Int, index: LineIndex, text: NSString) -> LexerState {
        guard language.carriesStateAcrossLines else { return LexerState() }
        let checkpoint = min(line / Self.checkpointStride, checkpoints.count - 1)
        var state = checkpoints[checkpoint]
        var current = checkpoint * Self.checkpointStride
        while current < line {
            _ = scan(current, lineRange(current, index: index, text: text), text: text, state: &state, collect: false)
            current += 1
        }
        return state
    }

    private func lineRange(_ line: Int, index: LineIndex, text: NSString) -> NSRange {
        let starts = index.starts
        let start = min(starts[line], text.length)
        let end = line + 1 < starts.count ? min(starts[line + 1], text.length) : text.length
        return NSRange(location: start, length: end - start)
    }

    /// Lexes one line and records the state at the start of the next line when it's a checkpoint.
    private mutating func scan(_ line: Int, _ range: NSRange, text: NSString, state: inout LexerState,
                               collect: Bool = true) -> [SyntaxToken] {
        scannedLineCount += 1
        var tokens: [SyntaxToken] = []
        if range.length <= maximumLineLength {
            var units = [UInt16](repeating: 0, count: range.length)
            if range.length > 0 { text.getCharacters(&units, range: range) }
            tokens = lexer.scan(units, state: &state, collect: collect)
        }
        let next = line + 1
        if next % Self.checkpointStride == 0 && next / Self.checkpointStride == checkpoints.count {
            checkpoints.append(state)
        }
        return tokens
    }
}
