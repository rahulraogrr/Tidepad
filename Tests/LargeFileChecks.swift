import Foundation
/// The large-file view's storage (Foundation only): the file (sparse line index, line breaks, BOM,
/// characters, words, UTF-16 refused) and the edit buffer (random edits against a reference, lines
/// after edits, undo, typing, find inside pieces and across seams, saving, re-basing).
@main struct LargeFileChecks {
    static func main() throws {
        try fileChecks()
        try bufferChecks()
        print("Large file checks passed: sparse line index, line breaks, BOM, characters and words, UTF-16 refused; 3,000 random edits, lines after edits, undo, typing, find (inside pieces, across seams, backwards, any case, wrap), lines as bytes, journals, save and re-base.")
    }
    static func fileChecks() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func file(_ s: String, _ name: String = "f.txt") throws -> LargeTextFile { let u = dir.appendingPathComponent(name); try Data(s.utf8).write(to: u); return try LargeTextFile(url: u) }
    // Lines
    var lines: [String] = []
    for k in 0..<1000 { lines.append("line \(k) café 中文") }
    let text = lines.joined(separator: "\n") + "\n"
    let f = try file(text)
    precondition(f.lineCount == 1001 && f.lineBreak == .lf, "count \(f.lineCount)")
    for k in [0, 1, 63, 64, 65, 127, 128, 500, 999] {
        precondition(f.text(in: f.lineRange(k)) == lines[k], "line \(k): \(f.text(in: f.lineRange(k)))")
        let r = f.lineRange(k)
        precondition(f.line(containing: r.lowerBound) == k && f.line(containing: r.upperBound) == k, "containing \(k)")
    }
    precondition(f.lineRange(1000).isEmpty && f.line(containing: f.count) == 1000)
    let rs = f.lineRanges(from: 60, count: 10)
    precondition(rs.count == 10 && zip(rs, 60..<70).allSatisfy { f.text(in: $0.0) == lines[$0.1] })
    precondition(f.longestLine == lines.map { $0.utf8.count }.max()!)
    // CRLF, CR, BOM
    let crlf = try file("\u{FEFF}ab\r\ncd\r\nef", "crlf.txt")
    precondition(crlf.hasByteOrderMark && crlf.contentStart == 3 && crlf.lineBreak == .crlf && crlf.lineCount == 3)
    precondition(crlf.text(in: crlf.lineRange(0)) == "ab" && crlf.text(in: crlf.lineRange(2)) == "ef")
    precondition(crlf.characterEnd(after: 5) == 7 && crlf.characterStart(before: 7) == 5, "CRLF is one character")
    let cr = try file("ab\rcd\r", "cr.txt")
    precondition(cr.lineBreak == .cr && cr.lineCount == 3 && cr.text(in: cr.lineRange(1)) == "cd")
    // Characters
    let u = try file("aé中😀b", "u.txt")
    precondition(u.characterCount(in: 0..<u.count) == 5)
    precondition(u.characterEnd(after: 1) == 3 && u.characterEnd(after: 3) == 6 && u.characterEnd(after: 6) == 10)
    precondition(u.characterStart(before: 10) == 6 && u.characterStart(before: 3) == 1)
    let w = try file("foo bar_baz9 qux", "w.txt")
    precondition(w.word(at: 6) == 4..<12)
    // UTF-16 refused
    do { _ = try file("\u{FEFF}hi", "x"); } catch {}
    let u16 = dir.appendingPathComponent("u16.txt"); try Data([0xFF, 0xFE, 0x41, 0]).write(to: u16)
    do { _ = try LargeTextFile(url: u16); preconditionFailure() } catch {}
    // empty
    let e = try file("", "e.txt"); precondition(e.lineCount == 1 && e.lineRange(0).isEmpty)
    // speed on 200MB
    let chunk = String(repeating: "2026-09-30 12:00:00 INFO request id=123 path=/api/v1/trades status=200 café\n", count: 100_000)
    let bigURL = dir.appendingPathComponent("200.txt"); FileManager.default.createFile(atPath: bigURL.path, contents: nil)
    let h = try FileHandle(forWritingTo: bigURL); let d = Data(chunk.utf8); for _ in 0..<25 { h.write(d) }; try h.close()
    let t0 = Date(); let L = try LargeTextFile(url: bigURL); let t1 = Date()
    let r0 = Date(); _ = L.lineRanges(from: L.lineCount / 2, count: 60); let r1 = Date()
    let B = LargeTextBuffer(file: L)
    let f0 = Date(); _ = B.find(Array("NOTTHERE".utf8), from: 0, wrap: false); let f1 = Date()
    let f2 = Date(); _ = B.find(Array("notthere".utf8), from: 0, matchCase: false, wrap: false); let f3 = Date()
    B.replace(B.count / 2..<B.count / 2, with: B.pieces(for: Array("x".utf8)))
    let e0 = Date(); for k in 0..<1000 { B.replace((B.count / 2 + k)..<(B.count / 2 + k), with: B.pieces(for: Array("y".utf8))) }; let e1 = Date()
    print(String(format: "  %d MB: open+index %.0f ms, 60 lines %.3f ms, find miss %.0f ms (%.1f GB/s), case-insensitive %.0f ms, 1,000 keystrokes %.2f ms", L.count >> 20, t1.timeIntervalSince(t0)*1000, r1.timeIntervalSince(r0)*1000, f1.timeIntervalSince(f0)*1000, Double(L.count)/f1.timeIntervalSince(f0)/1e9, f3.timeIntervalSince(f2)*1000, e1.timeIntervalSince(e0)*1000))
    try? FileManager.default.removeItem(at: dir)
    }

    static func bufferChecks() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func buffer(_ s: String, _ name: String = "f.txt") throws -> LargeTextBuffer { let u = dir.appendingPathComponent(name); try Data(s.utf8).write(to: u); return LargeTextBuffer(file: try LargeTextFile(url: u)) }
    var lines: [String] = []
    for k in 0..<1000 { lines.append("line \(k) café 中文") }
    let text = lines.joined(separator: "\n") + "\n"
    let b = try buffer(text)
    precondition(b.lineCount == 1001)
    for k in [0, 1, 63, 64, 65, 500, 999] {
        precondition(b.text(in: b.lineRange(k)) == lines[k])
        let r = b.lineRange(k); precondition(b.line(containing: r.lowerBound) == k && b.line(containing: r.upperBound) == k)
    }
    // Reference model and random edits
    var reference = Array(text.utf8)
    var rng = SystemRandomNumberGenerator()
    let samples = ["x", "\n", "ab\ncd", "é", "中文\n\n", "", "line"]
    for step in 0..<3000 {
        let a = Int.random(in: 0...reference.count, using: &rng)
        let len = Int.random(in: 0...min(8, reference.count - a), using: &rng) // About what is inserted, so the text keeps its size.
        let ins = Array(samples.randomElement(using: &rng)!.utf8)
        let removed = b.replace(a..<(a + len), with: b.pieces(for: ins))
        let removedBytes = removed.flatMap { Array(UnsafeBufferPointer(start: $0.source.base + $0.start, count: $0.length)) }
        precondition(removedBytes == Array(reference[a..<(a+len)]), "removed pieces step \(step)")
        reference.replaceSubrange(a..<(a + len), with: ins)
        precondition(b.count == reference.count)
        if step % 100 == 0 || step > 2990 {
            precondition(b.bytes(in: 0..<b.count) == reference, "content step \(step)")
            let refLines = reference.split(separator: 0x0A, omittingEmptySubsequences: false)
            precondition(b.lineCount == refLines.count, "lineCount \(b.lineCount) vs \(refLines.count)")
            for _ in 0..<30 {
                let L = Int.random(in: 0..<refLines.count, using: &rng)
                let r = b.lineRange(L)
                precondition(Array(b.bytes(in: r)) == Array(refLines[L]), "line \(L) step \(step)")
                precondition(b.line(containing: r.lowerBound) == L && b.line(containing: r.upperBound) == L, "containing \(L)")
            }
        }
    }
    // Undo: put back removed pieces
    let before = b.bytes(in: 0..<b.count)
    let at = b.count / 2
    let removed = b.replace(at..<(at + 10), with: b.pieces(for: Array("INSERTED".utf8)))
    _ = b.replace(at..<(at + 8), with: removed)
    precondition(b.bytes(in: 0..<b.count) == before, "undo round trip")
    // Typing coalesces pieces
    let t = try buffer("hello world", "t.txt")
    var pos = 5
    for c in " there" { t.replace(pos..<pos, with: t.pieces(for: Array(String(c).utf8))); pos += 1 }
    precondition(t.text(in: 0..<t.count) == "hello there world" && t.pieces.count == 3, "coalesced: \(t.pieces.count)")
    // Find across seams and inside pieces
    let f = try buffer("aaaa NEEDLE bbbb", "f2.txt")
    f.replace(8..<8, with: f.pieces(for: Array("-".utf8))) // NEE-DLE : breaks the match
    precondition(f.find(Array("NEEDLE".utf8), from: 0) == nil)
    f.replace(8..<9, with: [])
    precondition(f.find(Array("NEEDLE".utf8), from: 0) == 5..<11, "seam restored")
    f.replace(7..<7, with: f.pieces(for: Array("XX".utf8)))  // NEXXEDLE
    f.replace(7..<9, with: f.pieces(for: Array("E".utf8)))   // NEEEDLE? -> N E E E D L E
    precondition(f.text(in: 0..<f.count) == "aaaa NEEEDLE bbbb")
    precondition(f.find(Array("EEDLE".utf8), from: 0) == 7..<12, "seam match \(String(describing: f.find(Array("EEDLE".utf8), from: 0)))")
    precondition(f.find(Array("eedle".utf8), from: f.count, backwards: true, matchCase: false) == 7..<12, "backwards seam")
    precondition(f.find(Array("aaaa".utf8), from: 3) == 0..<4, "wrap")
    // Fuzz find vs reference
    for _ in 0..<200 {
        let hay = b.bytes(in: 0..<b.count)
        let start = Int.random(in: 0..<(hay.count - 6), using: &rng)
        let pat = Array(hay[start..<(start + Int.random(in: 1...6, using: &rng))])
        let from = Int.random(in: 0...hay.count, using: &rng)
        let got = b.find(pat, from: from, wrap: false)
        var expected: Range<Int>?
        var i = from; while i + pat.count <= hay.count { if Array(hay[i..<i+pat.count]) == pat { expected = i..<i+pat.count; break }; i += 1 }
        precondition(got == expected, "find fuzz \(pat) from \(from): \(String(describing: got)) vs \(String(describing: expected))")
        let gotB = b.find(pat, from: from, backwards: true, wrap: false)
        var expectedB: Range<Int>?
        i = from - pat.count; while i >= 0 { if Array(hay[i..<i+pat.count]) == pat { expectedB = i..<i+pat.count; break }; i -= 1 }
        precondition(gotB == expectedB, "backwards fuzz \(pat) from \(from): \(String(describing: gotB)) vs \(String(describing: expectedB))")
    }
    // Lines as bytes with their line breaks, across pieces.
    var gathered: [[UInt8]] = []
    b.forEachLine(from: 0, count: b.lineCount) { gathered.append(Array($0)); return true }
    precondition(gathered.count == b.lineCount && gathered.flatMap { $0 } == b.bytes(in: 0..<b.count), "forEachLine covers the text")
    var some = 0
    b.forEachLine(from: 10, count: 5) { line in some += 1; precondition(Array(line) == b.bytes(in: b.lineStart(10 + some - 1)..<b.lineStart(10 + some))); return some < 3 }
    precondition(some == 3, "forEachLine stops")
    // Snapshots don't follow later edits.
    let snap = b.snapshot(), snapBytes = snap.bytes(in: 0..<snap.count)
    b.replace(0..<0, with: b.pieces(for: Array("later".utf8)))
    precondition(snap.bytes(in: 0..<snap.count) == snapBytes && b.count == snap.count + 5, "snapshot")
    b.replace(0..<5, with: [])
    // Journal: edits kept as file ranges plus added bytes, replayed over the same file.
    let (journal, journalData) = b.journal()
    let journalBytes = try JSONEncoder().encode(journal)
    let replayed = try LargeTextBuffer(file: b.file, journal: try JSONDecoder().decode(LargeTextBuffer.Journal.self, from: journalBytes), data: journalData)
    precondition(replayed.bytes(in: 0..<replayed.count) == b.bytes(in: 0..<b.count) && replayed.lineCount == b.lineCount, "Journal replay")
    precondition(journalData.count < 100_000, "The journal holds the edits, not the file: \(journalData.count) bytes")
    precondition((try? LargeTextBuffer(file: b.file, journal: LargeTextBuffer.Journal(entries: [.init(fromFile: true, start: 0, length: b.file.count + 1)]), data: Data())) == nil, "A journal that doesn't fit the file is refused")
    // Save and rebase
    let out = dir.appendingPathComponent("saved.txt")
    try b.write(to: out)
    let savedData = try Data(contentsOf: out)
    precondition(Array(savedData) == b.bytes(in: 0..<b.count), "saved bytes")
    let content = b.bytes(in: 0..<b.count)
    b.rebase(on: try LargeTextFile(url: out))
    precondition(b.pieces.count == 1 && b.bytes(in: 0..<b.count) == content, "rebased")
    _ = b.replace(0..<0, with: removed) // old pieces still valid after rebase
    let (afterSave, afterSaveData) = b.journal() // Pieces from before the save are stored as bytes.
    let replayedAfterSave = try LargeTextBuffer(file: b.file, journal: afterSave, data: afterSaveData)
    precondition(replayedAfterSave.bytes(in: 0..<replayedAfterSave.count) == b.bytes(in: 0..<b.count), "Journal after a save")
    // CRLF + BOM
    let c = try buffer("\u{FEFF}ab\r\ncd\r\nef", "c.txt")
    precondition(c.contentStart == 3 && c.lineCount == 3 && c.text(in: c.lineRange(1)) == "cd")
    c.replace(0..<0, with: c.pieces(for: Array("X".utf8)))
    precondition(c.bytes(in: 0..<4) == [0xEF, 0xBB, 0xBF, 0x58], "edits never go before the BOM")
    precondition(c.characterEnd(after: 6) == 8 && c.characterStart(before: 8) == 6)
    try? FileManager.default.removeItem(at: dir)
    }
}
