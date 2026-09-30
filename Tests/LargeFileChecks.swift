import Foundation
/// The large-file view's storage (Foundation only): line index, CRLF/CR/BOM, characters, words,
/// byte search forwards, backwards and ignoring case, wrapping, UTF-16 refusal, and speed.
@main struct LargeFileChecks { static func main() throws {
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
    // Find
    let p = Array("café".utf8)
    let m = f.find(p, from: 0)!
    precondition(f.text(in: m) == "café" && f.line(containing: m.lowerBound) == 0)
    let m2 = f.find(p, from: m.upperBound)!
    precondition(f.line(containing: m2.lowerBound) == 1)
    let back = f.find(p, from: f.count, backwards: true)!
    precondition(f.line(containing: back.lowerBound) == 999, "backwards")
    precondition(f.find(Array("LINE 5".utf8), from: 0, matchCase: false).map { f.line(containing: $0.lowerBound) } == 5, "case-insensitive")
    precondition(f.find(Array("LINE 5".utf8), from: 0) == nil, "match case")
    let wrapped = f.find(Array("line 3 ".utf8), from: f.lineStart(500))!
    precondition(f.line(containing: wrapped.lowerBound) == 3, "wraps")
    precondition(f.find(Array("line 3 ".utf8), from: f.lineStart(500), wrap: false) == nil)
    precondition(f.find(Array("zzz".utf8), from: 0) == nil)
    // backwards across block boundary: big file
    var big = String(repeating: "x", count: 5_000_000) + "NEEDLE" + String(repeating: "y", count: 5_000_000)
    let b = try file(big, "big.txt")
    precondition(b.find(Array("NEEDLE".utf8), from: b.count, backwards: true) == 5_000_000..<5_000_006)
    precondition(b.find(Array("needle".utf8), from: 0, matchCase: false) == 5_000_000..<5_000_006)
    big = ""
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
    let f0 = Date(); _ = L.find(Array("NOTTHERE".utf8), from: 0, wrap: false); let f1 = Date()
    let f2 = Date(); _ = L.find(Array("notthere".utf8), from: 0, matchCase: false, wrap: false); let f3 = Date()
    print(String(format: "  %d MB: open+index %.0f ms, 60 lines %.3f ms, find miss %.0f ms (%.1f GB/s), case-insensitive %.0f ms", L.count >> 20, t1.timeIntervalSince(t0)*1000, r1.timeIntervalSince(r0)*1000, f1.timeIntervalSince(f0)*1000, Double(L.count)/f1.timeIntervalSince(f0)/1e9, f3.timeIntervalSince(f2)*1000))
    try? FileManager.default.removeItem(at: dir)
    print("Large file checks passed: sparse line index, line breaks, BOM, characters and words, find (forwards, backwards, any case, wrap), UTF-16 refused.")
}}
