import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A text file too large for NSTextView, opened for Tidepad's large-file view (see "Large-file spike"
/// in CLAUDE.md). Its bytes are memory-mapped, not read, and its lines are found through a sparse
/// index: the start of every 64th line, recorded in one fast scan. Positions are byte offsets into
/// the file. Phase A of the large-file view is read-only, so nothing here changes the file.
///
/// A memory-mapped file that another app shortens crashes the reader (SIGBUS) when it touches the
/// lost pages. So on APFS the file is first cloned (`clonefile`: instant, no extra space) and the
/// clone is mapped: changes to the original never reach it. Where cloning isn't possible (other
/// file systems), the file is read into memory instead, which is safe but costs its size in memory.
final class LargeTextFile: @unchecked Sendable {
    /// Files at least this large open in the large-file view. NSTextView's keystroke cost grows by
    /// about 0.22 ms per MB, so it passes the 16 ms frame budget at about 70 MB.
    static let threshold = 64 * 1_048_576
    /// Every this-many-th line start is recorded.
    static let sampleStride = 64

    enum LineBreak: Sendable { case lf, crlf, cr }

    enum OpenError: LocalizedError {
        case unsupportedEncoding(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedEncoding(let name):
                return "\(name) files larger than \(LargeTextFile.threshold / 1_048_576) MB can't be opened yet. Tidepad opens large files in UTF-8."
            }
        }
    }

    let url: URL
    /// The file's size in bytes.
    let count: Int
    /// Where the text starts: after a UTF-8 byte order mark, if there is one.
    let contentStart: Int
    let hasByteOrderMark: Bool
    let lineBreak: LineBreak
    let lineCount: Int
    /// The longest line, in bytes, for the width of the view.
    let longestLine: Int
    /// Whether the text was mapped from an APFS clone (false: read into memory).
    let isCloned: Bool

    let base: UnsafePointer<UInt8>
    private let mapped: Bool
    private let cloneFolder: URL?
    private let samples: [Int]
    private let breakByte: UInt8

    /// Maps (or reads) the file and indexes its lines.
    init(url: URL) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0

        var source = url.path
        var folder: URL?
        #if os(macOS)
        if size > 0, let replacement = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                                    appropriateFor: url, create: true) {
            let clone = replacement.appendingPathComponent(url.lastPathComponent)
            if clonefile(url.path, clone.path, 0) == 0 {
                source = clone.path
                folder = replacement
            } else {
                try? FileManager.default.removeItem(at: replacement)
            }
        }
        #endif

        let bytes: UnsafePointer<UInt8>, isMapped: Bool
        if size == 0 {
            bytes = UnsafePointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
            isMapped = false
        } else if folder != nil {
            let descriptor = open(source, O_RDONLY)
            guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url]) }
            defer { close(descriptor) }
            guard let region = mmap(nil, size, PROT_READ, MAP_SHARED, descriptor, 0), region != MAP_FAILED else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
            }
            bytes = UnsafePointer(region.assumingMemoryBound(to: UInt8.self))
            isMapped = true
        } else {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            let data = try Data(contentsOf: url)
            _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: size))
            bytes = UnsafePointer(buffer)
            isMapped = false
        }

        func starts(_ prefix: [UInt8]) -> Bool {
            size >= prefix.count && prefix.indices.allSatisfy { bytes[$0] == prefix[$0] }
        }
        if starts([0xFF, 0xFE]) || starts([0xFE, 0xFF]) {
            Self.release(base: bytes, count: size, mapped: isMapped, folder: folder)
            throw OpenError.unsupportedEncoding("UTF-16")
        }
        let bom = starts([0xEF, 0xBB, 0xBF])
        let first = bom ? 3 : 0

        // The line break: LF (and CRLF when the first LF follows a CR), or CR in files without LF.
        let content = UnsafeRawPointer(bytes + first), length = size - first
        let kind: LineBreak, separator: UInt8
        if let firstLF = memchr(content, 0x0A, length) {
            let offset = UnsafeRawPointer(firstLF) - UnsafeRawPointer(bytes)
            kind = offset > first && bytes[offset - 1] == 0x0D ? .crlf : .lf
            separator = 0x0A
        } else if length > 0 && memchr(content, 0x0D, length) != nil {
            kind = .cr
            separator = 0x0D
        } else {
            kind = .lf
            separator = 0x0A
        }

        // One scan: count lines, record every 64th start, and the longest line.
        var samples = [first]
        var lines = 1, longest = 0, lineStart = first
        var cursor = content, remaining = length
        while remaining > 0, let hit = memchr(cursor, Int32(separator), remaining) {
            let next = UnsafeRawPointer(hit) + 1
            let nextOffset = next - UnsafeRawPointer(bytes)
            longest = max(longest, nextOffset - 1 - lineStart)
            if lines % Self.sampleStride == 0 { samples.append(nextOffset) }
            lines += 1
            lineStart = nextOffset
            remaining -= next - cursor
            cursor = next
        }
        longest = max(longest, size - lineStart)

        self.url = url
        count = size
        base = bytes
        mapped = isMapped
        cloneFolder = folder
        isCloned = folder != nil
        hasByteOrderMark = bom
        contentStart = first
        lineBreak = kind
        breakByte = separator
        self.samples = samples
        lineCount = lines
        longestLine = longest
    }

    deinit { Self.release(base: base, count: count, mapped: mapped, folder: cloneFolder) }

    private static func release(base: UnsafePointer<UInt8>, count: Int, mapped: Bool, folder: URL?) {
        if mapped { munmap(UnsafeMutableRawPointer(mutating: base), count) } else { base.deallocate() }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Lines

    /// The offset just after the line break at or after `offset`, or the end of the file.
    private func nextLineStart(after offset: Int) -> Int {
        guard offset < count, let hit = memchr(base + offset, Int32(breakByte), count - offset) else { return count }
        return UnsafeRawPointer(hit) - UnsafeRawPointer(base) + 1
    }

    /// Where line `line` (0-based) starts.
    func lineStart(_ line: Int) -> Int {
        let line = min(max(0, line), lineCount - 1)
        var offset = samples[line / Self.sampleStride]
        for _ in 0..<(line % Self.sampleStride) { offset = nextLineStart(after: offset) }
        return offset
    }

    /// The bytes of `count` lines from `first` on, each without its line break.
    func lineRanges(from first: Int, count wanted: Int) -> [Range<Int>] {
        guard first < lineCount, wanted > 0 else { return [] }
        var result: [Range<Int>] = []
        result.reserveCapacity(min(wanted, lineCount - first))
        var start = lineStart(first)
        for line in first..<min(lineCount, first + wanted) {
            let isLast = line == lineCount - 1
            let next = isLast ? count : nextLineStart(after: start)
            var end = isLast ? count : next - 1
            if lineBreak == .crlf && !isLast && end > start && base[end - 1] == 0x0D { end -= 1 }
            result.append(start..<end)
            start = next
        }
        return result
    }

    /// The bytes of one line, without its line break.
    func lineRange(_ line: Int) -> Range<Int> { lineRanges(from: min(max(0, line), lineCount - 1), count: 1)[0] }

    /// The line an offset is on. An offset on a line break belongs to the line it ends.
    func line(containing offset: Int) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        let block = max(0, low - 1)
        var line = block * Self.sampleStride, start = samples[block]
        while line + 1 < lineCount {
            let next = nextLineStart(after: start)
            if next > offset { break }
            start = next
            line += 1
        }
        return line
    }

    // MARK: Text

    func text(in range: Range<Int>) -> String {
        let lower = max(contentStart, range.lowerBound), upper = min(count, range.upperBound)
        guard lower < upper else { return "" }
        return String(decoding: UnsafeBufferPointer(start: base + lower, count: upper - lower), as: UTF8.self)
    }

    func byte(at offset: Int) -> UInt8 { base[offset] }

    /// The Unicode characters (scalars) in a range: bytes that aren't UTF-8 continuation bytes.
    func characterCount(in range: Range<Int>) -> Int {
        var total = 0
        var k = max(contentStart, range.lowerBound)
        let end = min(count, range.upperBound)
        while k < end { if base[k] & 0xC0 != 0x80 { total += 1 }; k += 1 }
        return total
    }

    /// The start of the character after the one at `offset` (a CRLF counts as one).
    func characterEnd(after offset: Int) -> Int {
        guard offset < count else { return count }
        if base[offset] == 0x0D && offset + 1 < count && base[offset + 1] == 0x0A { return offset + 2 }
        var next = offset + 1
        while next < count && base[next] & 0xC0 == 0x80 { next += 1 }
        return next
    }

    /// The start of the character before `offset` (a CRLF counts as one).
    func characterStart(before offset: Int) -> Int {
        guard offset > contentStart else { return contentStart }
        if offset >= 2 && base[offset - 1] == 0x0A && base[offset - 2] == 0x0D { return offset - 2 }
        var previous = offset - 1
        while previous > contentStart && base[previous] & 0xC0 == 0x80 { previous -= 1 }
        return previous
    }

    /// Whether the byte at `offset` belongs to a word (letters, digits, underscore, and any non-ASCII).
    func isWordByte(at offset: Int) -> Bool {
        guard offset >= contentStart && offset < count else { return false }
        let byte = base[offset]
        return byte >= 0x80 || byte == 0x5F || (byte >= 0x30 && byte <= 0x39) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A)
    }

    /// The word around `offset`, for double-clicks.
    func word(at offset: Int) -> Range<Int> {
        guard isWordByte(at: offset) else { return offset..<characterEnd(after: offset) }
        var start = offset, end = offset
        while start > contentStart && isWordByte(at: start - 1) { start -= 1 }
        while end < count && isWordByte(at: end) { end += 1 }
        return start..<end
    }

    // MARK: Find

    /// The first match of `pattern` at or after `offset`, or the last match ending at or before it when
    /// `backwards`, wrapping round the file when `wrap`. ASCII letters match either case unless
    /// `matchCase`. Byte search on the mapped file: no text is decoded.
    func find(_ pattern: [UInt8], from offset: Int, backwards: Bool = false, matchCase: Bool = true, wrap: Bool = true,
              cancelled: () -> Bool = { false }) -> Range<Int>? {
        guard !pattern.isEmpty, pattern.count <= count - contentStart else { return nil }
        let offset = min(max(contentStart, offset), count)
        if backwards {
            if let match = lastMatch(pattern, before: offset, after: contentStart, matchCase: matchCase, cancelled: cancelled) { return match }
            return wrap ? lastMatch(pattern, before: count, after: offset, matchCase: matchCase, cancelled: cancelled) : nil
        }
        if let match = firstMatch(pattern, from: offset, to: count, matchCase: matchCase, cancelled: cancelled) { return match }
        return wrap ? firstMatch(pattern, from: contentStart, to: min(count, offset + pattern.count - 1), matchCase: matchCase, cancelled: cancelled) : nil
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }

    /// The first match wholly inside `start..<end`.
    private func firstMatch(_ pattern: [UInt8], from start: Int, to end: Int, matchCase: Bool, cancelled: () -> Bool) -> Range<Int>? {
        let n = pattern.count
        guard end - start >= n else { return nil }
        if matchCase {
            return pattern.withUnsafeBytes { needle -> Range<Int>? in
                var from = start
                while from <= end - n {
                    // In blocks of 64 MB, so a search can be cancelled.
                    let blockEnd = min(end, from + 64 * 1_048_576 + n - 1)
                    if let hit = memmem(base + from, blockEnd - from, needle.baseAddress!, n) {
                        let found = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                        return found..<(found + n)
                    }
                    if cancelled() { return nil }
                    from = blockEnd - n + 1
                }
                return nil
            }
        }
        let lower = pattern.map(Self.lowercased)
        let first = lower[0], firstUpper = first >= 0x61 && first <= 0x7A ? first - 0x20 : first
        let last = end - n // The last place a match can start.
        /// The next place `byte` appears at or after `from`, or Int.max.
        func next(_ byte: UInt8, from: Int) -> Int {
            guard from <= last, let hit = memchr(base + from, Int32(byte), last + 1 - from) else { return .max }
            return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
        }
        // The next place the first byte appears in each case, each found again only once passed.
        var nextLower = next(first, from: start)
        var nextUpper = first == firstUpper ? Int.max : next(firstUpper, from: start)
        var checked = 0
        while true {
            let candidate = min(nextLower, nextUpper)
            guard candidate <= last else { return nil }
            var k = 1
            while k < n && Self.lowercased(base[candidate + k]) == lower[k] { k += 1 }
            if k == n { return candidate..<(candidate + n) }
            if candidate == nextLower { nextLower = next(first, from: candidate + 1) }
            if candidate == nextUpper { nextUpper = next(firstUpper, from: candidate + 1) }
            checked += 1
            if checked % 1_000_000 == 0 && cancelled() { return nil }
        }
    }

    /// The last match ending at or before `end` and starting at or after `start`, searching back in blocks.
    private func lastMatch(_ pattern: [UInt8], before end: Int, after start: Int, matchCase: Bool, cancelled: () -> Bool) -> Range<Int>? {
        let n = pattern.count, block = 4 * 1_048_576
        var blockEnd = end
        while blockEnd - start >= n {
            let blockStart = max(start, blockEnd - block)
            var last: Range<Int>?, from = blockStart
            while let match = firstMatch(pattern, from: from, to: blockEnd, matchCase: matchCase, cancelled: cancelled) {
                last = match
                from = match.lowerBound + 1
            }
            if let last { return last }
            if cancelled() || blockStart == start { return nil }
            blockEnd = blockStart + n - 1
        }
        return nil
    }
}
