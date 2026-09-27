import Foundation

struct FileSearchUpdate: Sendable {
    var results: [SearchResult] = []
    var files = 0
    var skipped = 0
    var matches = 0
    var truncated = false
    var error: String?
}

/// One serial I/O worker bounds memory and disk pressure. Publication is awaited for backpressure.
struct FindInFilesService: Sendable {
    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumResults = 100_000

    func run(directory: URL, filters: String, engine: SearchEngine, progress: Progress,
             publish: @Sendable (FileSearchUpdate) async -> Void) async {
        let timing = SearchTiming("Find in Files"); defer { timing.finish() }
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            var update = FileSearchUpdate(); update.error = "Directory does not exist or is unreadable."
            await publish(update); return
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var update = FileSearchUpdate()
        let patterns = filters.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let matchers = patterns.compactMap { pattern -> NSRegularExpression? in
            let pattern = pattern == "*.*" ? "*" : pattern
            let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".")
            return try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive])
        }
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return }
        var lastPublish = ContinuousClock.now
        while let url = walker.nextObject() as? URL {
            if progress.isCancelled || Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            if !matchers.isEmpty && !matchers.contains(where: { $0.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil }) { continue }
            update.files += 1
            progress.completedUnitCount = Int64(update.files)
            let batch: [SearchResult]? = autoreleasepool {
                guard (values.fileSize ?? Int.max) <= Self.maximumFileBytes,
                      let text = try? Self.readText(url) else { return nil }
                let snapshot = SearchSnapshot(text: text, revision: 0)
                var builder = SearchResultBuilder(snapshot), rows: [SearchResult] = []
                engine.enumerate(snapshot, cancelled: { progress.isCancelled || Task.isCancelled }) { range, _ in
                    if update.matches + rows.count >= Self.maximumResults { update.truncated = true; return false }
                    rows.append(builder.result(range, documentID: nil, url: url, name: url.path, revision: nil,
                                               fileDate: values.contentModificationDate, fileSize: values.fileSize))
                    return true
                }
                return rows
            }
            if let batch { update.matches += batch.count; update.results.append(contentsOf: batch) } else { update.skipped += 1 }
            if update.results.count >= 256 || lastPublish.duration(to: .now) > .milliseconds(100) {
                await publish(update); update.results.removeAll(keepingCapacity: true); lastPublish = .now
            }
            if update.truncated { break }
        }
        await publish(update)
    }

    static func readText(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sample = try handle.read(upToCount: 8192) ?? Data()
        let encoding: String.Encoding
        let bom: Int
        if sample.starts(with: [0xFF, 0xFE, 0, 0]) || sample.starts(with: [0, 0, 0xFE, 0xFF]) {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        } else if sample.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian; bom = 2 }
        else if sample.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian; bom = 2 }
        else {
            let controls = sample.filter { $0 < 32 && ![9, 10, 12, 13].contains($0) }.count
            guard !sample.contains(0), controls * 100 <= max(1, sample.count) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            encoding = .utf8; bom = sample.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        }
        try handle.seek(toOffset: UInt64(bom))
        // Bound reads even if a file grows after resource-value inspection.
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes, let text = String(data: data, encoding: encoding) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}
