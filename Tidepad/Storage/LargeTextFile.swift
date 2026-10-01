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
                return "\(name) files larger than \(LargeTextFile.threshold / 1_048_576) MB can't be opened yet. TidePad opens large files in UTF-8."
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
    /// The file's stamp, taken before it was cloned: the version these bytes are, as far as can be
    /// told (a change made while opening then still shows as a change).
    let identity: FileStamp?
    /// Whether the text is valid UTF-8 (after a UTF-8 BOM). Tidepad edits large files only in UTF-8,
    /// so a file in another encoding (Latin-1, Shift-JIS) or with stray bytes is opened read-only:
    /// typing UTF-8 into it would mix encodings.
    let isValidUTF8: Bool
    /// The clone that's mapped, while this is open (nil when the file was read into memory).
    var clonePath: String? { cloneFolder.map { $0.appendingPathComponent(cloneName).path } }

    let base: UnsafePointer<UInt8>
    private let mapped: Bool
    private let cloneFolder: URL?
    private let cloneName: String
    private let samples: [Int]
    private let breakByte: UInt8

    /// Maps (or reads) the file and indexes its lines. `contents`: where to read the bytes from instead
    /// of `url` (a copy kept with the session, for edits made against an earlier version of the file).
    /// `lineBreak`: the kind of line break to index by, instead of the one found in the file (after a
    /// save, the buffer's own, so the two always agree).
    init(url: URL, contentsOf contents: URL? = nil, lineBreak wantedBreak: LineBreak? = nil) throws {
        // Links are followed: the clone and the stamp are of the file they point to.
        let original = (contents ?? url).resolvingSymlinksInPath()
        identity = FileStamp(original)

        var source = original.path
        var folder: URL?
        let name = url.lastPathComponent
        #if os(macOS)
        if let replacement = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                          appropriateFor: original, create: true) {
            let clone = replacement.appendingPathComponent(name)
            if clonefile(original.path, clone.path, 0) == 0 {
                source = clone.path
                folder = replacement
            } else {
                try? FileManager.default.removeItem(at: replacement)
            }
        }
        #endif

        // The size is the clone's own (fstat), never an earlier look at the path: the original may have
        // changed in between, and mapping past the end of a file crashes.
        let bytes: UnsafePointer<UInt8>, isMapped: Bool, size: Int
        if folder != nil {
            let descriptor = open(source, O_RDONLY)
            guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url]) }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url]) }
            size = Int(info.st_size)
            if size == 0 {
                bytes = UnsafePointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))
                isMapped = false
            } else {
                guard let region = mmap(nil, size, PROT_READ, MAP_SHARED, descriptor, 0), region != MAP_FAILED else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
                }
                bytes = UnsafePointer(region.assumingMemoryBound(to: UInt8.self))
                isMapped = true
            }
        } else {
            // Read straight into one buffer (never the file twice in memory), up to the size it had
            // when opened, or less if it shrank meanwhile.
            let descriptor = open(source, O_RDONLY)
            guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url]) }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url]) }
            let capacity = Int(info.st_size)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, capacity))
            var filled = 0
            while filled < capacity {
                let got = read(descriptor, buffer + filled, capacity - filled)
                if got > 0 { filled += got; continue }
                if got < 0 && errno == EINTR { continue }
                if got < 0 {
                    buffer.deallocate()
                    throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
                }
                break // The end, earlier than expected.
            }
            size = filled
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
        if let wantedBreak {
            kind = wantedBreak
            separator = wantedBreak == .cr ? 0x0D : 0x0A
        } else if let firstLF = memchr(content, 0x0A, length) {
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

        let valid = UTF8Bytes.isValid(bytes + first, count: length)

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
        cloneName = name
        isValidUTF8 = valid
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

    // MARK: Line breaks, for the edit buffer

    /// The line-break byte this file's lines end with (LF, or CR in CR-only files).
    var lineBreakByte: UInt8 { breakByte }
}

/// Where a LargeTextBuffer's pieces point: the file, or a block of added text. Both stay at fixed
/// addresses for their lifetime, so pieces can point into them.
protocol LargeTextSource: AnyObject, Sendable {
    var base: UnsafePointer<UInt8> { get }
    /// Line-break bytes in a range of this source.
    func breaks(in range: Range<Int>, byte: UInt8) -> Int
    /// The offset of the `number`th line-break byte at or after `start` (1-based).
    func breakOffset(_ number: Int, from start: Int, byte: UInt8) -> Int
}

extension LargeTextFile: LargeTextSource {
    /// Through the sparse index: the line numbers of the two ends (or by counting, for another byte).
    func breaks(in range: Range<Int>, byte: UInt8) -> Int {
        guard !range.isEmpty else { return 0 }
        guard byte == breakByte else { return UTF8Bytes.count(byte, in: base + range.lowerBound, count: range.count) }
        return line(containing: range.upperBound) - line(containing: range.lowerBound)
    }
    func breakOffset(_ number: Int, from start: Int, byte: UInt8) -> Int {
        guard byte == breakByte else {
            var offset = start - 1
            for _ in 0..<number {
                guard offset + 1 < count, let hit = memchr(base + offset + 1, Int32(byte), count - offset - 1) else { return count }
                offset = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
            }
            return offset
        }
        return lineStart(line(containing: start) + number) - 1
    }
}

/// UTF-8 as the large-file view reads it. Valid sequences are characters; each byte that doesn't
/// start one is a character of its own, shown as U+FFFD. Decoding, counting UTF-16 units and mapping
/// them back to bytes all follow this one rule, so offsets never drift on invalid bytes.
enum UTF8Bytes {
    /// The UTF-8 sequence at `index`: its length in bytes, and in UTF-16 units.
    static func sequence(_ b: UnsafeBufferPointer<UInt8>, at index: Int) -> (bytes: Int, units: Int) {
        let lead = b[index]
        if lead < 0x80 { return (1, 1) }
        func follows(_ k: Int, _ low: UInt8 = 0x80, _ high: UInt8 = 0xBF) -> Bool {
            index + k < b.count && b[index + k] >= low && b[index + k] <= high
        }
        switch lead {
        case 0xC2...0xDF: return follows(1) ? (2, 1) : (1, 1)
        case 0xE0: return follows(1, 0xA0) && follows(2) ? (3, 1) : (1, 1)
        case 0xE1...0xEC, 0xEE, 0xEF: return follows(1) && follows(2) ? (3, 1) : (1, 1)
        case 0xED: return follows(1, 0x80, 0x9F) && follows(2) ? (3, 1) : (1, 1)
        case 0xF0: return follows(1, 0x90) && follows(2) && follows(3) ? (4, 2) : (1, 1)
        case 0xF1...0xF3: return follows(1) && follows(2) && follows(3) ? (4, 2) : (1, 1)
        case 0xF4: return follows(1, 0x80, 0x8F) && follows(2) && follows(3) ? (4, 2) : (1, 1)
        default: return (1, 1)
        }
    }

    /// Whether the bytes are valid UTF-8. Runs of ASCII are checked eight bytes at a time.
    static func isValid(_ base: UnsafePointer<UInt8>, count: Int) -> Bool {
        let b = UnsafeBufferPointer(start: base, count: count)
        let raw = UnsafeRawPointer(base)
        var k = 0
        while k < count {
            while k + 8 <= count && raw.loadUnaligned(fromByteOffset: k, as: UInt64.self) & 0x8080_8080_8080_8080 == 0 { k += 8 }
            guard k < count else { break }
            if b[k] < 0x80 { k += 1; continue }
            let step = sequence(b, at: k)
            if step.bytes == 1 { return false }
            k += step.bytes
        }
        return true
    }

    /// UTF-16 units of the bytes.
    static func units(_ b: UnsafeBufferPointer<UInt8>) -> Int {
        var k = 0, units = 0
        while k < b.count {
            let step = sequence(b, at: k)
            units += step.units
            k += step.bytes
        }
        return units
    }

    /// How many bytes from the start make up `target` UTF-16 units (never splitting a character: a
    /// target inside a surrogate pair stops before it).
    static func bytes(ofUnits target: Int, in b: UnsafeBufferPointer<UInt8>) -> Int {
        var k = 0, units = 0
        while k < b.count && units < target {
            let step = sequence(b, at: k)
            if units + step.units > target { break }
            units += step.units
            k += step.bytes
        }
        return k
    }

    /// The text, with valid UTF-8 decoded by the standard library and anything else by the rule above.
    static func decode(_ bytes: [UInt8]) -> String {
        let valid = bytes.withUnsafeBufferPointer { $0.isEmpty || isValid($0.baseAddress!, count: $0.count) }
        if valid { return String(decoding: bytes, as: UTF8.self) }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count)
        bytes.withUnsafeBufferPointer { b in
            var k = 0
            while k < b.count {
                let step = sequence(b, at: k)
                var scalar: UInt32
                switch step.bytes {
                case 1: scalar = b[k] < 0x80 ? UInt32(b[k]) : 0xFFFD
                case 2: scalar = UInt32(b[k] & 0x1F) << 6 | UInt32(b[k + 1] & 0x3F)
                case 3: scalar = UInt32(b[k] & 0x0F) << 12 | UInt32(b[k + 1] & 0x3F) << 6 | UInt32(b[k + 2] & 0x3F)
                default: scalar = UInt32(b[k] & 0x07) << 18 | UInt32(b[k + 1] & 0x3F) << 12 | UInt32(b[k + 2] & 0x3F) << 6 | UInt32(b[k + 3] & 0x3F)
                }
                if scalar >= 0x10000 {
                    scalar -= 0x10000
                    units.append(UInt16(0xD800 + (scalar >> 10)))
                    units.append(UInt16(0xDC00 + (scalar & 0x3FF)))
                } else {
                    units.append(UInt16(scalar))
                }
                k += step.bytes
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// How many times `byte` occurs.
    static func count(_ byte: UInt8, in base: UnsafePointer<UInt8>, count: Int) -> Int {
        var total = 0, cursor = 0
        while cursor < count, let hit = memchr(base + cursor, Int32(byte), count - cursor) {
            total += 1
            cursor = UnsafeRawPointer(hit) - UnsafeRawPointer(base) + 1
        }
        return total
    }
}
