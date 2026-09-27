import Foundation

/// Times lazy colouring of increasing sizes: the first screen, a jump to the end, typing there, and an
/// edit at the top followed by looking at the end again. JSON lines are independent; Swift has block
/// comments, so reaching the end means walking the lexer over every line once.
@main struct SyntaxPerformance {
    static func milliseconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    static func main() {
        let samples: [(SyntaxLanguage, String)] = [
            (.json, "  {\n    \"id\": 42,\n    \"name\": \"Tidepad\",\n    \"url\": \"https://example.com/a\",\n    \"ok\": true\n  },\n"),
            (.swift, "    /* note */ let value = \"text\" + 42 // realistic Swift\n    if ready { return nil }\n")
        ]
        for (language, record) in samples {
            for megabytes in [1, 10, 50] {
                let count = megabytes * 1_048_576 / record.utf8.count
                let text = NSMutableString(string: "[\n" + String(repeating: record, count: count) + "]\n")
                let index = LineIndex()
                index.rebuild(text as String)
                var engine = IncrementalSyntaxEngine(language: language)
                let screen = 6_000 // About 60 lines of 100 characters.
                let top = milliseconds { _ = engine.tokens(in: NSRange(location: 0, length: screen), index: index, text: text) }
                let end = NSRange(location: text.length - screen, length: screen)
                let jump = milliseconds { _ = engine.tokens(in: end, index: index, text: text) }
                let typing = milliseconds {
                    for _ in 0..<100 {
                        let at = text.length - 50
                        text.replaceCharacters(in: NSRange(location: at, length: 0), with: "x")
                        index.applyEdit(in: text, range: NSRange(location: at, length: 1), delta: 1)
                        engine.invalidate(fromLine: index.line(at: at) - 1)
                        _ = engine.tokens(in: NSRange(location: text.length - screen, length: screen), index: index, text: text)
                    }
                } / 100
                text.replaceCharacters(in: NSRange(location: 2, length: 0), with: "/")
                index.applyEdit(in: text, range: NSRange(location: 2, length: 1), delta: 1)
                engine.invalidate(fromLine: 0)
                let relex = milliseconds { _ = engine.tokens(in: NSRange(location: text.length - screen, length: screen), index: index, text: text) }
                print(String(format: "SYNTAX %@ %3d MB (%d lines): first screen %.2f ms, jump to end %.1f ms, per keystroke at end %.3f ms, edit at top then end %.1f ms",
                             language.displayName, megabytes, index.starts.count, top, jump, typing, relex))
            }
        }
    }
}
