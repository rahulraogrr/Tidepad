import Foundation
/// Find and replace in the large-file view (Foundation only): LargeTextSearch against the normal
/// editor's SearchEngine on the same text. Tiny chunks force matches across cuts; edited buffers put
/// matches across pieces. Non-ASCII text (Telugu, emoji, café), CRLF, invalid UTF-8, a BOM, whole
/// words, case, ^ and $, empty matches, capture templates, Replace All and its limit, and speed.
@main struct LargeSearchChecks {
    static func main() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var fileNumber = 0
        func buffer(_ bytes: [UInt8]) throws -> LargeTextBuffer {
            fileNumber += 1
            let url = dir.appendingPathComponent("f\(fileNumber).txt")
            try Data(bytes).write(to: url)
            return LargeTextBuffer(file: try LargeTextFile(url: url))
        }

        // Text with a bit of everything; some of it inserted as edits, so there are many pieces.
        var rng = SystemRandomNumberGenerator()
        let words = ["line", "café", "CAFÉ", "తెలుగు", "భాష", "😀", "mail@host", "x_y", "42", "2026", "Straße", "a", "ab"]
        var lines: [String] = []
        for k in 0..<1500 {
            var line = "line \(k)"
            for _ in 0..<Int.random(in: 0...8, using: &rng) { line += " " + words.randomElement(using: &rng)! }
            lines.append(line)
        }
        for lineBreak in ["\n", "\r\n"] {
            let text = lines.joined(separator: lineBreak) + lineBreak
            let b = try buffer(Array(text.utf8))
            var reference = Array(text.utf8)
            for _ in 0..<300 { // Edits: insert whole words at word gaps, so the reference stays valid UTF-8.
                let spaces = reference.indices.filter { reference[$0] == 0x20 }
                let at = spaces.randomElement(using: &rng)!
                let insert = Array((" " + words.randomElement(using: &rng)!).utf8)
                b.replace(at..<at, with: b.pieces(for: insert))
                reference.insert(contentsOf: insert, at: at)
            }
            precondition(b.bytes(in: 0..<b.count) == reference && b.pieces.count > 100)
            let string = String(decoding: reference, as: UTF8.self)
            try compare(b, string, lineBreak: lineBreak == "\n" ? "LF" : "CRLF")
        }

        // Bytes that aren't UTF-8: matches around them still land on the right bytes.
        var invalid: [UInt8] = Array("ab ".utf8)
        invalid += [0xFF]; invalid += Array("12 ".utf8); invalid += [0xC3]; invalid += Array(" x😀 34 ".utf8)
        invalid += [0xE0, 0x80]; invalid += Array("56".utf8)
        let ib = try buffer(invalid)
        var found: [[UInt8]] = []
        try LargeTextSearch(SearchQuery(text: "\\d+", mode: .regex)).forEachMatch(in: ib, range: 0..<ib.count) { found.append(ib.bytes(in: $0.range)); return true }
        precondition(found == [Array("12".utf8), Array("34".utf8), Array("56".utf8)], "invalid UTF-8: \(found)")
        let emoji = try LargeTextSearch(SearchQuery(text: "😀", mode: .regex)).next(in: ib, from: 0)
        precondition(emoji.map { ib.bytes(in: $0) } == Array("😀".utf8), "emoji after invalid bytes")

        // A chunk that starts with U+FEFF keeps it (Foundation would drop it).
        let feff = try buffer(Array("a\u{FEFF}42".utf8))
        let chunk = LargeTextChunk(feff, 1..<feff.count)
        precondition(chunk.text.length == 3 && chunk.byteOffset(ofUnit: 1) == 4 && chunk.unitOffset(ofByte: 5) == 2, "U+FEFF chunk")
        // A byte order mark is never searched or replaced.
        let bom = try buffer(Array("\u{FEFF}^x\nx".utf8))
        let starts = try LargeTextSearch(SearchQuery(text: "^", mode: .regex)).replacements(in: bom, range: 0..<bom.count, template: ">")
        precondition(starts.map(\.range) == [3..<3, 6..<6], "line starts after a BOM: \(starts.map(\.range))")

        // Replace All's limit: nothing is planned past it.
        let many = try buffer(Array(String(repeating: "a,", count: 150_000).utf8))
        do { _ = try LargeTextSearch(SearchQuery(text: ",")).replacements(in: many, range: 0..<many.count, template: ";"); preconditionFailure("limit") }
        catch SearchFailure.tooManyReplacements {}
        let sharedEdits = try LargeTextSearch(SearchQuery(text: ",")).replacements(in: many, range: 0..<many.count, template: ";", limit: 200_000)
        let sharedPieces = many.pieces(in: 0..<many.count, replacing: sharedEdits)
        precondition(Set(sharedPieces.filter { !($0.source === many.file) }.map(\.start)).count == 1, "equal replacements share added text")

        try speed(dir)
        print("Large search checks passed: regex, whole word, case, ^ and $, empty matches, templates, Replace All and Replace across chunk cuts and pieces (LF and CRLF, Telugu, emoji), invalid UTF-8, BOM, limit.")
    }

    /// Every query, with tiny chunks, against SearchEngine over the whole text.
    static func compare(_ b: LargeTextBuffer, _ string: String, lineBreak: String) throws {
        // UTF-16 offset -> byte offset.
        var bytesAt: [Int] = [0]
        var total = 0
        for scalar in string.unicodeScalars {
            total += String(scalar).utf8.count
            if scalar.value >= 0x10000 { bytesAt.append(-1) }
            bytesAt.append(total)
        }
        func bytes(_ r: NSRange) -> Range<Int> { bytesAt[r.location]..<bytesAt[NSMaxRange(r)] }
        let offsets = bytesAt.filter { $0 >= 0 }
        let unitAt = Dictionary(uniqueKeysWithValues: bytesAt.enumerated().filter { $0.element >= 0 }.map { ($0.element, $0.offset) })

        var queries: [SearchQuery] = [
            SearchQuery(text: "\\d+", mode: .regex),
            SearchQuery(text: "^line \\d+", mode: .regex),
            SearchQuery(text: "\\d+$", mode: .regex),
            SearchQuery(text: "తె\\w+", mode: .regex),
            SearchQuery(text: "(\\w+)@(\\w+)", mode: .regex),
            SearchQuery(text: "\\d\\r?\\nline", mode: .regex), // Across line breaks.
            SearchQuery(text: "(?<=line )\\d+", mode: .regex),
            SearchQuery(text: "^", mode: .regex),               // Empty matches.
            SearchQuery(text: "a*", mode: .regex),
            SearchQuery(text: "😀", mode: .regex),
            SearchQuery(text: "STRA", mode: .normal),
            SearchQuery(text: "LINE", mode: .normal),
            SearchQuery(text: "\\n", mode: .extended)
        ]
        var q = SearchQuery(text: "café"); q.wholeWord = true; queries.append(q)
        q = SearchQuery(text: "café"); q.matchCase = false; queries.append(q)          // Non-ASCII, any case: Unicode folding.
        q = SearchQuery(text: "a"); q.wholeWord = true; q.matchCase = true; queries.append(q)
        q = SearchQuery(text: "Café", mode: .regex); q.matchCase = false; queries.append(q)

        for query in queries {
            let engine = try SearchEngine(query)
            let snapshot = SearchSnapshot(text: string, revision: 0)
            let expected = engine.matches(snapshot).ranges.map(bytes)
            for (chunkSize, overlap, context) in [(256, 64, 16), (1000, 200, 7), (4 << 20, 64 << 10, 4 << 10)] {
                let search = try LargeTextSearch(query, chunkSize: chunkSize, overlap: overlap, context: context)
                var got: [Range<Int>] = []
                search.forEachMatch(in: b, range: 0..<b.count) { got.append($0.range); return true }
                precondition(got == expected, "\(lineBreak) \(query.text) chunk \(chunkSize): \(got.count) vs \(expected.count), first difference \(String(describing: zip(got, expected).first { $0 != $1 }))")
                precondition(search.count(in: b) == expected.count)
                // Next and previous from random places, with wrap.
                for _ in 0..<25 {
                    let offset = offsets.randomElement()!
                    for backwards in [false, true] {
                        let want = engine.next(snapshot, from: unitAt[offset]!, backwards: backwards).map { bytes($0.range) }
                        let have = search.next(in: b, from: offset, backwards: backwards)
                        if query.text == "a*" || query.text == "^" { continue } // Empty matches: the editors step over them differently.
                        precondition(have == want, "\(lineBreak) next \(query.text) from \(offset) back \(backwards): \(String(describing: have)) vs \(String(describing: want))")
                    }
                }
                // Replace All, with a template in regex mode.
                let template = query.mode == .regex ? "<$0|\\$>" : "[r]"
                let edits = try search.replacements(in: b, range: 0..<b.count, template: template, limit: 1_000_000)
                let pieces = b.pieces(in: b.contentStart..<b.count, replacing: edits)
                let replaced = String(decoding: pieces.flatMap { Array(UnsafeBufferPointer(start: $0.source.base + $0.start, count: $0.length)) }, as: UTF8.self)
                if let plan = try engine.replacement(snapshot, template: template) {
                    let expectedText = (string as NSString).replacingCharacters(in: plan.range, with: plan.text)
                    precondition(replaced == expectedText, "\(lineBreak) Replace All \(query.text) chunk \(chunkSize)")
                }
            }
            // Replace: only when the selection is exactly a match.
            if let first = expected.first(where: { !$0.isEmpty }) {
                let search = try LargeTextSearch(query)
                let exact = try search.replacement(forSelection: first, in: b, template: "R")
                let wider = try search.replacement(forSelection: first.lowerBound..<(first.upperBound + 1), in: b, template: "R")
                precondition(exact == Array("R".utf8), "Replace \(query.text)")
                precondition(wider == nil || query.text == "a*",
                             "Replace needs an exact match \(query.text)")
            }
        }
    }

    static func speed(_ dir: URL) throws {
        let block = String(repeating: "2026-09-30 12:00:00 INFO request id=123 path=/api/v1/trades status=200 café\n", count: 100_000)
        let url = dir.appendingPathComponent("speed.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let data = Data(block.utf8)
        for _ in 0..<10 { handle.write(data) }
        try handle.close()
        let b = LargeTextBuffer(file: try LargeTextFile(url: url))
        func time(_ body: () throws -> Void) rethrows -> Double { let start = Date(); try body(); return Date().timeIntervalSince(start) }
        let regex = try LargeTextSearch(SearchQuery(text: "status=5\\d\\d", mode: .regex))
        let miss = time { precondition(regex.next(in: b, from: 0, wrap: false) == nil) }
        var word = SearchQuery(text: "CAFÉ"); word.wholeWord = true; word.matchCase = false
        let words = try LargeTextSearch(word)
        var counted = 0
        let count = time { counted = words.count(in: b) }
        precondition(counted == 1_000_000)
        let plain = try LargeTextSearch(SearchQuery(text: "trades"))
        var edits: [LargeTextSearch.Edit] = []
        let plan = try time { edits = try plain.replacements(in: b, range: 0..<b.count, template: "orders", limit: 1_000_000) }
        let apply = time { b.replace(b.contentStart..<b.count, with: b.pieces(in: b.contentStart..<b.count, replacing: edits)) }
        let mb = Double(b.file.count) / 1_048_576
        print(String(format: "  %.0f MB: regex miss %.0f ms (%.0f MB/s), whole-word any-case count of 1,000,000 %.0f ms, Replace All of 1,000,000: plan %.0f ms, apply %.0f ms",
                     mb, miss * 1000, mb / miss, count * 1000, plan * 1000, apply * 1000))
    }
}
