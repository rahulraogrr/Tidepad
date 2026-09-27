import Foundation

actor FileCollector {
    var rows: [SearchResult] = []
    var latest = FileSearchUpdate()
    func append(_ update: FileSearchUpdate) { rows += update.results; latest = update }
}
@main struct SearchChecks {
    static func expect(_ value: Bool, _ name: String) { if !value { fatalError(name) } }
    static func source(_ text: String) -> SearchSnapshot { SearchSnapshot(text: text, revision: 1) }
    static func main() async throws {
        let sample = source("cat Cat scatter cat\n😀 café e\u{301} cat\r\nlast")
        var query = SearchQuery(text: "cat", matchCase: true)
        var engine = try SearchEngine(query)
        expect(engine.next(sample, from: 0)?.range == NSRange(location: 0, length: 3), "first")
        expect(engine.next(sample, from: 4)?.range.location == 9, "forward")
        expect(engine.next(sample, from: 8, backwards: true)?.range.location == 0, "backward")
        expect(engine.next(sample, from: (sample.text as NSString).length)?.range.location == 0, "wrap")
        query.wrap = false; engine = try SearchEngine(query)
        expect(engine.next(sample, from: (sample.text as NSString).length) == nil, "no wrap")
        query.matchCase = false; query.wholeWord = true; engine = try SearchEngine(query)
        expect(engine.matches(sample).ranges.count == 4, "case and whole word")
        expect(try SearchEngine(SearchQuery(text: "absent")).next(sample, from: 0) == nil, "absent")
        for (escaped, decoded) in [("\\n", "\n"), ("\\r", "\r"), ("\\t", "\t"), ("\\0", "\0"), ("\\\\", "\\")] {
            engine = try SearchEngine(SearchQuery(text: escaped, mode: .extended))
            expect(engine.matches(source("a" + decoded + "b")).ranges == [NSRange(location: 1, length: (decoded as NSString).length)], "extended \(escaped)")
        }
        do { _ = try SearchEngine(SearchQuery(text: "[", mode: .regex)); fatalError("invalid regex") } catch {}
        do { _ = try SearchEngine(SearchQuery(text: "\\q", mode: .extended)); fatalError("invalid escape") } catch {}
        engine = try SearchEngine(SearchQuery(text: "(cat) (\\d+)", mode: .regex))
        let captures = source("cat 12 cat 34")
        let replaced = try engine.replacement(captures, template: "$2-$1")
        expect(replaced?.text == "12-cat 34-cat" && replaced?.count == 2, "capture replacement")
        let exact = try engine.replacement(captures, template: "$2", range: NSRange(location: 7, length: 6), exact: true)
        expect(exact?.text == "34", "replace current")
        let scoped = try engine.replacement(captures, template: "x", range: NSRange(location: 0, length: 6))
        expect(scoped?.count == 1, "selection bounds")
        engine = try SearchEngine(SearchQuery(text: "(?=.)", mode: .regex))
        let zero = engine.matches(source("😀x"))
        expect(zero.ranges == [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)], "zero width surrogate")
        expect(engine.next(source("😀x"), from: 0, excluding: NSRange(location: 0, length: 0))?.range.location == 2, "zero advancement")
        expect(try engine.replacement(source("😀x"), template: "_")?.text == "_😀_", "zero replacement span")
        for term in ["😀", "café", "e\u{301}"] {
            engine = try SearchEngine(SearchQuery(text: term, matchCase: true))
            let range = (sample.text as NSString).range(of: term, options: .literal)
            expect(engine.next(sample, from: 0)?.range == range, "unicode \(term)")
        }
        engine = try SearchEngine(SearchQuery(text: "cat", wholeWord: true))
        let ranges = engine.matches(sample).ranges
        var builder = SearchResultBuilder(sample)
        let rows = ranges.map { builder.result($0, documentID: nil, url: nil, name: "test", revision: 1) }
        expect(rows.last?.line == 2 && rows.last?.column == 10 && rows.last?.preview.contains("café") == true, "line column preview")
        let longUnicode = source(String(repeating: "😀e\u{301} ", count: 1000))
        let unicodeEngine = try SearchEngine(SearchQuery(text: "e\u{301}", matchCase: true))
        var longBuilder = SearchResultBuilder(longUnicode)
        let longRows = unicodeEngine.matches(longUnicode).ranges.map { longBuilder.result($0, documentID: nil, url: nil, name: "long", revision: 1) }
        expect(longRows.last?.column == 2999, "incremental grapheme columns on long single line")
        var history = SearchHistory()
        for n in 0..<30 { history.record(find: "\(n)", replacement: "r", directory: "/tmp", filter: "*.*") }
        history.record(find: "29", replacement: "r", directory: "/tmp", filter: "*.*")
        expect(history.finds.count == 20 && history.finds.first == "29" && history.replacements.count == 1, "history")
        try await files()
        print("PASS search: normal/extended/regex, captures, zero-width, Unicode, results, history, recursive files and cancellation")
        try await benchmarks()
    }
    static func files() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TidepadSearch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "needle 😀".write(to: root.appendingPathComponent("a.java"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("nested/b.xml"), atomically: true, encoding: .utf16)
        try "needle".write(to: root.appendingPathComponent("excluded.log"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary.java"))
        try "needle".write(to: root.appendingPathComponent("unreadable.java"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent("unreadable.java").path)
        let collector = FileCollector(), progress = Progress(totalUnitCount: -1)
        let engine = try SearchEngine(SearchQuery(text: "needle"))
        await FindInFilesService().run(directory: root, filters: "*.java;*.xml", engine: engine, progress: progress) { await collector.append($0) }
        let rows = await collector.rows, update = await collector.latest
        expect(rows.count == 2 && update.skipped == 2, "files filters recursion binary unreadable utf16")
        let bigEndian = root.appendingPathComponent("big.txt")
        let encoded = "needle 😀".data(using: .utf16BigEndian) ?? Data()
        try (Data([0xFE, 0xFF]) + encoded).write(to: bigEndian)
        expect(try FindInFilesService.readText(bigEndian) == "needle 😀", "UTF16 BE decode")
        let bom = root.appendingPathComponent("bom.txt")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("needle".utf8)).write(to: bom)
        expect(try FindInFilesService.readText(bom) == "needle", "UTF8 BOM decode")
        let dense = root.appendingPathComponent("dense.txt")
        try String(repeating: "needle\n", count: 100_100).write(to: dense, atomically: true, encoding: .utf8)
        let many = FileCollector()
        await FindInFilesService().run(directory: root, filters: "dense.txt", engine: engine, progress: Progress(totalUnitCount: -1)) { await many.append($0) }
        let manyRows = await many.rows, manyUpdate = await many.latest
        expect(manyRows.count == 100_000 && manyUpdate.truncated, "bounded large result count")
        let noExtension = root.appendingPathComponent("README")
        try "needle".write(to: noExtension, atomically: true, encoding: .utf8)
        let all = FileCollector()
        await FindInFilesService().run(directory: root, filters: "README", engine: engine, progress: Progress(totalUnitCount: -1)) { await all.append($0) }
        let extensionless = await all.rows
        expect(extensionless.count == 1, "extensionless text")
        let cancelled = Progress(totalUnitCount: -1); cancelled.cancel()
        let empty = FileCollector()
        await FindInFilesService().run(directory: root, filters: "*.*", engine: engine, progress: cancelled) { await empty.append($0) }
        let emptyRows = await empty.rows
        expect(emptyRows.isEmpty, "cancelled traversal")
    }
    static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components; return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    static func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now; let result = try body()
        print("BENCH \(name): \(String(format: "%.3f", milliseconds(start.duration(to: .now)))) ms")
        return result
    }
    static func benchmarks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TidepadBench-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = "2026-09-26 INFO worker=04 request=1234 status=ok needle processed successfully payload=abcdefghijklmnopqrstuvwxyz0123456789\n"
        let literal = try SearchEngine(SearchQuery(text: "needle", matchCase: true))
        let regex = try SearchEngine(SearchQuery(text: "request=(\\d+).*?needle", mode: .regex))
        for size in [100_000, 1_000_000, 10_000_000] {
            let text = String(repeating: line, count: size / line.utf8.count)
            let snap = source(text); print("FIXTURE \(text.utf8.count) bytes")
            _ = timed("\(size) next") { literal.next(snap, from: 0) }
            _ = timed("\(size) previous") { literal.next(snap, from: (text as NSString).length, backwards: true) }
            _ = timed("\(size) findAll") { literal.matches(snap) }
            _ = timed("\(size) regexPrevious") { regex.next(snap, from: (text as NSString).length, backwards: true) }
            _ = timed("\(size) regexAll") { regex.matches(snap) }
            _ = try timed("\(size) replaceAll") { try literal.replacement(snap, template: "replacement") }
            let folder = root.appendingPathComponent("\(size)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent("sample.log"), atomically: true, encoding: .utf8)
            let start = ContinuousClock.now
            await FindInFilesService().run(directory: folder, filters: "*.log", engine: literal, progress: Progress(totalUnitCount: -1)) { _ in }
            print("BENCH \(size) files: \(String(format: "%.3f", milliseconds(start.duration(to: .now)))) ms")
        }
        let progress = Progress(totalUnitCount: -1)
        let task = Task.detached { await FindInFilesService().run(directory: root, filters: "*.*", engine: regex, progress: progress) { _ in } }
        try await Task.sleep(for: .milliseconds(5)); let start = ContinuousClock.now; progress.cancel(); task.cancel(); await task.value
        print("BENCH cancellation: \(String(format: "%.3f", milliseconds(start.duration(to: .now)))) ms")
    }
}
