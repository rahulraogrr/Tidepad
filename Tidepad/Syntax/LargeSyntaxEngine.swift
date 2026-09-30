import Foundation

/// Syntax colours for the large-file view, with the normal editor's lexer (LineLexer), one line at a
/// time and only for the lines drawn.
///
/// A line's colours can depend on the lines before it (a block comment or a string that spans lines),
/// so the lexer's state is recorded at the start of every `stride`-th line. Those states are worked
/// out in the background from the top of the file down (`advance`), because lexing hundreds of MB
/// takes seconds. Until the background pass reaches a line, its state is guessed by lexing the
/// `warmUp` lines above it from a fresh state, which is right unless a comment or string opened
/// further up is still open; the view redraws once the exact state arrives. An edit drops the states
/// after the edited line, and the background pass starts again from there.
struct LargeSyntaxEngine {
    static let stride = 256
    static let warmUp = 200
    /// Longer lines aren't lexed (and don't change the state), as in the normal editor.
    static let maximumLineLength = 100_000

    private(set) var language: SyntaxLanguage
    private var lexer: LineLexer
    /// `checkpoints[k]`: the lexer state at the start of line `k * stride`.
    private(set) var checkpoints = [LexerState()]
    /// The state at the start of a line, left by the last line coloured, so lines drawn in order
    /// don't each lex up from a checkpoint.
    private var cursor: (line: Int, state: LexerState)?

    init(language: SyntaxLanguage) {
        self.language = language
        lexer = LineLexer(language: language)
    }

    var isEnabled: Bool { language != .plain }

    mutating func setLanguage(_ language: SyntaxLanguage) {
        guard language != self.language else { return }
        self.language = language
        lexer = LineLexer(language: language)
        invalidateAll()
    }

    mutating func invalidateAll() {
        checkpoints = [LexerState()]
        cursor = nil
    }

    /// After an edit on `line`: states up to the start of that line still hold.
    mutating func invalidate(fromLine line: Int) {
        let keep = max(0, line) / Self.stride + 1
        if checkpoints.count > keep { checkpoints.removeSubrange(keep...) }
        if let cursor, cursor.line > line { self.cursor = nil }
    }

    /// Whether a line's colours are exact, not guessed: it's lexed from a checkpoint.
    func isExact(_ line: Int) -> Bool {
        guard language.carriesStateAcrossLines else { return true }
        return line / Self.stride < checkpoints.count || line - (checkpoints.count - 1) * Self.stride <= Self.warmUp
    }

    /// Gives lines' bytes, each with its line break: `count` of them from `first` on, in order, to
    /// `body` (LargeTextBuffer.forEachLine), stopping when it returns false.
    typealias Lines = (_ first: Int, _ count: Int, _ body: (UnsafeBufferPointer<UInt8>) -> Bool) -> Void

    /// A line's tokens. `units` is the line's text in UTF-16 with its line break (what's drawn);
    /// `lines` reads the lines above it as bytes, when their state has to be worked out.
    mutating func tokens(line: Int, units: [UInt16], lines: Lines) -> [SyntaxToken] {
        guard isEnabled else { return [] }
        var state = startState(line, lines: lines)
        let tokens = units.count <= Self.maximumLineLength ? lexer.scan(units, state: &state) : []
        cursor = (line + 1, state)
        return tokens
    }

    private mutating func startState(_ line: Int, lines: Lines) -> LexerState {
        guard language.carriesStateAcrossLines else { return LexerState() }
        var from: Int, state: LexerState
        let known = line / Self.stride
        if known < checkpoints.count {
            from = known * Self.stride
            state = checkpoints[known]
        } else {
            // Past the background pass: from the last checkpoint if it's close, or guess.
            let last = (checkpoints.count - 1) * Self.stride
            if line - last <= Self.warmUp { from = last; state = checkpoints[checkpoints.count - 1] }
            else { from = line - Self.warmUp; state = LexerState() }
        }
        if let cursor, cursor.line <= line, cursor.line > from { from = cursor.line; state = cursor.state }
        if from < line { Self.follow(lexer, lines: lines, from: from, count: line - from, state: &state) }
        return state
    }

    /// Advances the state over lines, lexing their bytes in place (no conversion to UTF-16).
    private static func follow(_ lexer: LineLexer, lines: Lines, from first: Int, count: Int, state: inout LexerState) {
        var current = state
        lines(first, count) { bytes in
            if bytes.count <= maximumLineLength { _ = lexer.scan(utf8: bytes, state: &current, collect: false) }
            return true
        }
        state = current
    }

    // MARK: Background pass

    /// The states for the next checkpoints, as the background pass works them out: lexes from
    /// checkpoint `index` (whose state is `state`) for up to `count` checkpoints, over a document of
    /// `lineCount` lines.
    static func advance(language: SyntaxLanguage, from index: Int, state: LexerState, count: Int, lineCount: Int,
                        lines: Lines, cancelled: () -> Bool = { false }) -> [LexerState] {
        let lexer = LineLexer(language: language)
        var state = state, result: [LexerState] = []
        var line = index * stride
        while result.count < count && line + stride <= lineCount && !cancelled() {
            follow(lexer, lines: lines, from: line, count: stride, state: &state)
            line += stride
            result.append(state)
        }
        return result
    }

    /// Adds checkpoints from the background pass, if they continue the ones held (nothing was
    /// invalidated since the pass started from checkpoint `index`).
    @discardableResult
    mutating func append(_ states: [LexerState], after index: Int) -> Bool {
        guard index == checkpoints.count - 1 else { return false }
        checkpoints.append(contentsOf: states)
        cursor = nil // It may hold a guessed state that these replace.
        return true
    }
}
