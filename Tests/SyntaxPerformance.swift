import Foundation

@main struct SyntaxPerformance {
    static func main() {
        for size in [100_000, 1_000_000, 10_000_000] {
            let source = String(repeating: "let value = 42 // realistic Swift example\n", count: size / 41)
            var engine = IncrementalSyntaxEngine()
            let start = ContinuousClock.now
            engine.update(text: source, language: .swift)
            let full = start.duration(to: .now)
            let edit = ContinuousClock.now
            engine.update(text: "x" + source, language: .swift)
            let payload = engine.lines.reduce(0) { $0 + $1.text.utf8.count + $1.tokens.count * MemoryLayout<SyntaxToken>.stride }
                + engine.lines.count * MemoryLayout<SyntaxLine>.stride + engine.starts.count * MemoryLayout<Int>.stride
            print("CACHE \(size) estimatedPayloadBytes=\(payload) lines=\(engine.lines.count) tokens=\(engine.lines.reduce(0) { $0 + $1.tokens.count })")
            print("SYNTAX \(size) full=\(full) incremental=\(edit.duration(to: .now)) reusedLines=\(engine.lines.count - engine.scannedLineCount)")
        }
    }
}
