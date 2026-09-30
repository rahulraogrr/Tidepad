import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The editable text of a large file: a piece table in bytes over the memory-mapped file
/// (LargeTextFile). The document is a list of pieces, each pointing into the file or into a block of
/// added text; an edit splits at most two pieces and inserts new ones, so it costs the same whatever
/// the file's size. Each piece knows how many line breaks it holds, so lines are found by a binary
/// search over pieces and then the file's sparse line index, never by scanning the document.
///
/// Positions are byte offsets. The whole file is covered, including a UTF-8 byte order mark, which
/// edits never touch (`contentStart`). Pieces are values that keep their sources alive, so undo can
/// put back pieces from before a save, when the buffer was re-based on the newly saved file.
final class LargeTextBuffer: @unchecked Sendable {
    struct Piece: Sendable {
        let source: any LargeTextSource
        let start: Int
        let length: Int
        let breaks: Int
    }

    /// The file the buffer started from (or was last saved to).
    private(set) var file: LargeTextFile
    private(set) var pieces: [Piece] = []
    /// ends[k]: the document offset just after piece k. breakEnds[k]: line breaks up to its end.
    private var ends: [Int] = []
    private var breakEnds: [Int] = []
    /// Bumped by every change, so views know their caches are stale.
    private(set) var revision = 0
    /// The longest line seen, for the view's width (grows with edits; never shrinks).
    private(set) var longestLine: Int
    let breakByte: UInt8
    private var block: AddedBlock?

    init(file: LargeTextFile) {
        self.file = file
        breakByte = file.lineBreakByte
        longestLine = file.longestLine
        reset(to: file)
    }

    /// A read-only copy for searching in the background while editing goes on. It shares the file and
    /// the added blocks, which only ever grow past the bytes existing pieces use.
    func snapshot() -> LargeTextBuffer { LargeTextBuffer(copying: self) }

    private init(copying other: LargeTextBuffer) {
        file = other.file
        pieces = other.pieces
        ends = other.ends
        breakEnds = other.breakEnds
        revision = other.revision
        longestLine = other.longestLine
        breakByte = other.breakByte
    }

    private func reset(to file: LargeTextFile) {
        self.file = file
        pieces = file.count > 0 ? [Piece(source: file, start: 0, length: file.count, breaks: file.lineCount - 1)] : []
        rebuildSums(from: 0)
        revision += 1
    }

    /// After saving: the saved file holds exactly this text, so the buffer starts over from it (one
    /// piece). Pieces kept by undo still point into the old file and added blocks, which stay alive.
    func rebase(on newFile: LargeTextFile) {
        precondition(newFile.count == count, "A re-based file must hold the same text")
        longestLine = max(longestLine, newFile.longestLine)
        reset(to: newFile)
    }

    var count: Int { ends.last ?? 0 }
    var contentStart: Int { file.contentStart }
    var lineBreak: LargeTextFile.LineBreak { file.lineBreak }
    var lineCount: Int { (breakEnds.last ?? 0) + 1 }
    var hasByteOrderMark: Bool { file.hasByteOrderMark }

    private func rebuildSums(from index: Int) {
        let from = max(0, min(index, pieces.count))
        ends.removeSubrange(from...)
        breakEnds.removeSubrange(from...)
        var end = from > 0 ? ends[from - 1] : 0, breaks = from > 0 ? breakEnds[from - 1] : 0
        for piece in pieces[from...] {
            end += piece.length
            breaks += piece.breaks
            ends.append(end)
            breakEnds.append(breaks)
        }
    }

    private func pieceStart(_ index: Int) -> Int { index > 0 ? ends[index - 1] : 0 }

    /// The piece holding `offset` (the first whose end is past it); pieces.count at the very end.
    private func pieceIndex(containing offset: Int) -> Int {
        var low = 0, high = ends.count
        while low < high {
            let middle = (low + high) / 2
            if ends[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: Editing

    /// Pieces for new text, in blocks of added text that never move.
    func pieces(for bytes: [UInt8]) -> [Piece] {
        guard !bytes.isEmpty else { return [] }
        if block == nil || block!.remaining < bytes.count { block = AddedBlock(capacity: max(1 << 20, bytes.count)) }
        let block = block!
        let start = block.append(bytes)
        longestLine = max(longestLine, bytes.count)
        return [Piece(source: block, start: start, length: bytes.count, breaks: block.breaks(in: start..<(start + bytes.count), byte: breakByte))]
    }

    /// The pieces holding a range, for undo.
    func pieces(in range: Range<Int>) -> [Piece] {
        guard !range.isEmpty else { return [] }
        var result: [Piece] = []
        var index = pieceIndex(containing: range.lowerBound)
        while index < pieces.count && pieceStart(index) < range.upperBound {
            let piece = pieces[index], start = pieceStart(index)
            let lower = max(range.lowerBound, start) - start, upper = min(range.upperBound, start + piece.length) - start
            result.append(slice(piece, lower..<upper))
            index += 1
        }
        return result
    }

    private func slice(_ piece: Piece, _ local: Range<Int>) -> Piece {
        if local.lowerBound == 0 && local.count == piece.length { return piece }
        let start = piece.start + local.lowerBound
        return Piece(source: piece.source, start: start, length: local.count,
                     breaks: piece.source.breaks(in: start..<(start + local.count), byte: breakByte))
    }

    /// Replaces a range with pieces; returns the pieces removed (for undo). Typing right after the
    /// last added text extends its piece instead of adding one per keystroke.
    @discardableResult
    func replace(_ range: Range<Int>, with inserted: [Piece]) -> [Piece] {
        let lower = min(max(contentStart, range.lowerBound), count)
        let range = lower..<min(count, max(lower, range.upperBound))
        let removed = pieces(in: range)
        let first = pieceIndex(containing: range.lowerBound)
        var replacement: [Piece] = []
        var low = first, high = first // pieces[low..<high] are replaced
        if first < pieces.count, range.lowerBound > pieceStart(first) {
            replacement.append(slice(pieces[first], 0..<(range.lowerBound - pieceStart(first))))
        }
        replacement.append(contentsOf: inserted)
        let after = pieceIndex(containing: range.upperBound) // The piece holding the first byte after the range.
        if after < pieces.count {
            let cut = range.upperBound - pieceStart(after)
            if cut > 0 { replacement.append(slice(pieces[after], cut..<pieces[after].length)); high = after + 1 }
            else { high = after }
        } else {
            high = pieces.count
        }
        // Join neighbours that continue each other in the same source (typing, or undoing a split).
        if low > 0 { low -= 1; replacement.insert(pieces[low], at: 0) }
        if high < pieces.count { replacement.append(pieces[high]); high += 1 }
        var merged: [Piece] = []
        for piece in replacement where piece.length > 0 {
            if let last = merged.last, last.source === piece.source, last.start + last.length == piece.start {
                merged[merged.count - 1] = Piece(source: last.source, start: last.start, length: last.length + piece.length,
                                                 breaks: last.breaks + piece.breaks)
            } else {
                merged.append(piece)
            }
        }
        pieces.replaceSubrange(low..<high, with: merged)
        rebuildSums(from: low)
        revision += 1
        return removed
    }

    // MARK: Reading

    /// Calls `body` with each stretch of contiguous bytes in `range` (in order, or in reverse), with its
    /// document offset; stops when it returns false.
    func forEachSegment(in range: Range<Int>, reverse: Bool = false,
                        _ body: (_ offset: Int, _ bytes: UnsafePointer<UInt8>, _ count: Int) -> Bool) {
        guard !range.isEmpty else { return }
        let first = pieceIndex(containing: range.lowerBound)
        var last = pieceIndex(containing: range.upperBound - 1)
        last = min(last, pieces.count - 1)
        guard first <= last else { return }
        var index = reverse ? last : first
        while index >= first && index <= last {
            let piece = pieces[index], start = pieceStart(index)
            let lower = max(range.lowerBound, start), upper = min(range.upperBound, start + piece.length)
            if lower < upper && !body(lower, piece.source.base + piece.start + (lower - start), upper - lower) { return }
            index += reverse ? -1 : 1
        }
    }

    func byte(at offset: Int) -> UInt8 {
        let index = pieceIndex(containing: offset)
        precondition(index < pieces.count, "Offset out of bounds")
        return pieces[index].source.base[pieces[index].start + offset - pieceStart(index)]
    }

    func bytes(in range: Range<Int>) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(range.count)
        forEachSegment(in: range) { _, bytes, count in
            result.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count))
            return true
        }
        return result
    }

    func text(in range: Range<Int>) -> String {
        let lower = max(contentStart, range.lowerBound), upper = min(count, range.upperBound)
        guard lower < upper else { return "" }
        var text = ""
        var pending: [UInt8] = []
        forEachSegment(in: lower..<upper) { _, bytes, count in
            pending.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count))
            return true
        }
        text = String(decoding: pending, as: UTF8.self)
        return text
    }

    // MARK: Lines

    /// The offset just after the line break at or after `offset`, or the end.
    func nextLineStart(after offset: Int) -> Int {
        var result = count
        forEachSegment(in: offset..<count) { start, bytes, length in
            guard let hit = memchr(bytes, Int32(breakByte), length) else { return true }
            result = start + (UnsafeRawPointer(hit) - UnsafeRawPointer(bytes)) + 1
            return false
        }
        return result
    }

    /// Where line `line` (0-based) starts.
    func lineStart(_ line: Int) -> Int {
        let line = min(max(0, line), lineCount - 1)
        guard line > 0 else { return contentStart }
        var low = 0, high = breakEnds.count // The first piece whose breaks reach `line`.
        while low < high {
            let middle = (low + high) / 2
            if breakEnds[middle] < line { low = middle + 1 } else { high = middle }
        }
        let piece = pieces[low], before = low > 0 ? breakEnds[low - 1] : 0
        let offset = piece.source.breakOffset(line - before, from: piece.start, byte: breakByte)
        return pieceStart(low) + (offset - piece.start) + 1
    }

    /// The bytes of `wanted` lines from `first` on, each without its line break.
    func lineRanges(from first: Int, count wanted: Int) -> [Range<Int>] {
        guard first < lineCount, wanted > 0 else { return [] }
        var result: [Range<Int>] = []
        var start = lineStart(first)
        for line in first..<min(lineCount, first + wanted) {
            let isLast = line == lineCount - 1
            let next = isLast ? count : nextLineStart(after: start)
            var end = isLast ? count : next - 1
            if lineBreak == .crlf && !isLast && end > start && byte(at: end - 1) == 0x0D { end -= 1 }
            result.append(start..<end)
            start = next
        }
        return result
    }

    func lineRange(_ line: Int) -> Range<Int> { lineRanges(from: min(max(0, line), lineCount - 1), count: 1)[0] }

    /// The line an offset is on. An offset on a line break belongs to the line it ends.
    func line(containing offset: Int) -> Int {
        let offset = min(max(0, offset), count)
        let index = pieceIndex(containing: offset)
        guard index < pieces.count else { return lineCount - 1 }
        let piece = pieces[index], start = pieceStart(index)
        let before = index > 0 ? breakEnds[index - 1] : 0
        return before + piece.source.breaks(in: piece.start..<(piece.start + offset - start), byte: breakByte)
    }

    // MARK: Characters and words

    func characterCount(in range: Range<Int>) -> Int {
        var total = 0
        forEachSegment(in: max(contentStart, range.lowerBound)..<min(count, range.upperBound)) { _, bytes, length in
            for k in 0..<length where bytes[k] & 0xC0 != 0x80 { total += 1 }
            return true
        }
        return total
    }

    /// The start of the character after the one at `offset` (a CRLF counts as one).
    func characterEnd(after offset: Int) -> Int {
        guard offset < count else { return count }
        if byte(at: offset) == 0x0D && offset + 1 < count && byte(at: offset + 1) == 0x0A { return offset + 2 }
        var next = offset + 1
        while next < count && byte(at: next) & 0xC0 == 0x80 { next += 1 }
        return next
    }

    /// The start of the character before `offset` (a CRLF counts as one).
    func characterStart(before offset: Int) -> Int {
        guard offset > contentStart else { return contentStart }
        if offset >= 2 && byte(at: offset - 1) == 0x0A && byte(at: offset - 2) == 0x0D && offset - 2 >= contentStart { return offset - 2 }
        var previous = offset - 1
        while previous > contentStart && byte(at: previous) & 0xC0 == 0x80 { previous -= 1 }
        return previous
    }

    func isWordByte(at offset: Int) -> Bool {
        guard offset >= contentStart && offset < count else { return false }
        let byte = byte(at: offset)
        return byte >= 0x80 || byte == 0x5F || (byte >= 0x30 && byte <= 0x39) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A)
    }

    func word(at offset: Int) -> Range<Int> {
        guard isWordByte(at: offset) else { return offset..<characterEnd(after: offset) }
        var start = offset, end = offset
        while start > contentStart && isWordByte(at: start - 1) { start -= 1 }
        while end < count && isWordByte(at: end) { end += 1 }
        return start..<end
    }

    // MARK: Find

    /// The first match of `pattern` at or after `offset`, or the last one ending at or before it when
    /// `backwards`, wrapping round when `wrap`. ASCII letters match either case unless `matchCase`.
    func find(_ pattern: [UInt8], from offset: Int, backwards: Bool = false, matchCase: Bool = true, wrap: Bool = true,
              cancelled: () -> Bool = { false }) -> Range<Int>? {
        guard !pattern.isEmpty, pattern.count <= count - contentStart else { return nil }
        let offset = min(max(contentStart, offset), count)
        if backwards {
            if let match = lastMatch(pattern, in: contentStart..<offset, matchCase: matchCase, cancelled: cancelled) { return match }
            return wrap ? lastMatch(pattern, in: max(contentStart, offset - pattern.count + 1)..<count, matchCase: matchCase, cancelled: cancelled) : nil
        }
        if let match = firstMatch(pattern, in: offset..<count, matchCase: matchCase, cancelled: cancelled) { return match }
        return wrap ? firstMatch(pattern, in: contentStart..<min(count, offset + pattern.count - 1), matchCase: matchCase, cancelled: cancelled) : nil
    }

    /// The first match wholly inside `range`: searched within each piece, then across each seam.
    private func firstMatch(_ pattern: [UInt8], in range: Range<Int>, matchCase: Bool, cancelled: () -> Bool) -> Range<Int>? {
        let n = pattern.count
        guard range.count >= n else { return nil }
        var found: Range<Int>?
        var previousEnd: Int?
        forEachSegment(in: range) { start, bytes, length in
            // A match across the seam with the previous piece comes before any inside this one.
            if let seam = previousEnd, n > 1 {
                let lower = max(range.lowerBound, seam - (n - 1)), upper = min(range.upperBound, seam + (n - 1))
                let window = self.bytes(in: lower..<upper)
                if let local = window.withUnsafeBufferPointer({ ByteSearch.first(pattern, in: $0.baseAddress!, count: $0.count, matchCase: matchCase, cancelled: cancelled) }),
                   lower + local.lowerBound < seam && lower + local.upperBound > seam {
                    found = (lower + local.lowerBound)..<(lower + local.upperBound)
                    return false
                }
            }
            if let local = ByteSearch.first(pattern, in: bytes, count: length, matchCase: matchCase, cancelled: cancelled) {
                found = (start + local.lowerBound)..<(start + local.upperBound)
                return false
            }
            previousEnd = start + length
            return !cancelled()
        }
        return found
    }

    /// The last match wholly inside `range`.
    private func lastMatch(_ pattern: [UInt8], in range: Range<Int>, matchCase: Bool, cancelled: () -> Bool) -> Range<Int>? {
        let n = pattern.count
        guard range.count >= n else { return nil }
        var found: Range<Int>?
        var nextStart: Int?
        forEachSegment(in: range, reverse: true) { start, bytes, length in
            if let seam = nextStart, n > 1 {
                let lower = max(range.lowerBound, seam - (n - 1)), upper = min(range.upperBound, seam + (n - 1))
                let window = self.bytes(in: lower..<upper)
                if let local = window.withUnsafeBufferPointer({ ByteSearch.last(pattern, in: $0.baseAddress!, count: $0.count, matchCase: matchCase, cancelled: cancelled) }),
                   lower + local.lowerBound < seam && lower + local.upperBound > seam {
                    found = (lower + local.lowerBound)..<(lower + local.upperBound)
                    return false
                }
            }
            if let local = ByteSearch.last(pattern, in: bytes, count: length, matchCase: matchCase, cancelled: cancelled) {
                found = (start + local.lowerBound)..<(start + local.upperBound)
                return false
            }
            nextStart = start
            return !cancelled()
        }
        return found
    }

    // MARK: Saving

    /// Streams the text to `url`: to a temporary file on the same volume, then swapped in atomically, so
    /// the file on disk is never half written. Pieces from the file are copied straight from its
    /// mapping; nothing is decoded. Checks there's room first.
    func write(to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let folder = target.deletingLastPathComponent()
        #if os(macOS)
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < Int64(count) + 16 * 1_048_576 {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSURLErrorKey: url])
        }
        #endif
        let files = FileManager.default
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent(target.lastPathComponent)
        guard files.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
        let descriptor = open(temporary.path, O_WRONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: url]) }
        var failure: Int32 = 0
        for piece in pieces where failure == 0 {
            var pointer = piece.source.base + piece.start, remaining = piece.length
            while remaining > 0 {
                let written = posixWrite(descriptor, pointer, min(remaining, 64 * 1_048_576))
                if written < 0 { if errno == EINTR { continue }; failure = errno; break }
                pointer += written
                remaining -= written
            }
        }
        if failure == 0 && fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        if failure != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [NSURLErrorKey: url]) }
        if files.fileExists(atPath: target.path) {
            _ = try files.replaceItemAt(target, withItemAt: temporary)
        } else {
            try files.moveItem(at: temporary, to: target)
        }
    }
}

private func posixWrite(_ descriptor: Int32, _ pointer: UnsafePointer<UInt8>, _ count: Int) -> Int {
    write(descriptor, pointer, count)
}

/// Added text: a fixed block of memory that never moves, so pieces can point into it.
final class AddedBlock: LargeTextSource, @unchecked Sendable {
    let base: UnsafePointer<UInt8>
    private let storage: UnsafeMutablePointer<UInt8>
    private let capacity: Int
    private(set) var used = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        base = UnsafePointer(storage)
    }
    deinit { storage.deallocate() }

    var remaining: Int { capacity - used }

    /// Copies bytes in; returns where they start.
    func append(_ bytes: [UInt8]) -> Int {
        precondition(bytes.count <= remaining)
        let start = used
        bytes.withUnsafeBufferPointer { (storage + start).update(from: $0.baseAddress!, count: $0.count) }
        used += bytes.count
        return start
    }

    func breaks(in range: Range<Int>, byte: UInt8) -> Int {
        var total = 0, cursor = range.lowerBound
        while cursor < range.upperBound, let hit = memchr(base + cursor, Int32(byte), range.upperBound - cursor) {
            total += 1
            cursor = UnsafeRawPointer(hit) - UnsafeRawPointer(base) + 1
        }
        return total
    }

    func breakOffset(_ number: Int, from start: Int, byte: UInt8) -> Int {
        var cursor = start, found = 0
        while cursor < used, let hit = memchr(base + cursor, Int32(byte), used - cursor) {
            let offset = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
            found += 1
            if found == number { return offset }
            cursor = offset + 1
        }
        return used
    }
}

/// Byte search in contiguous memory: memmem when case matters, otherwise the first byte in either
/// case (memchr) and a comparison of the rest.
enum ByteSearch {
    private static func lowercased(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }

    static func first(_ pattern: [UInt8], in base: UnsafePointer<UInt8>, count: Int, matchCase: Bool,
                      cancelled: () -> Bool = { false }) -> Range<Int>? {
        let n = pattern.count
        guard n > 0, count >= n else { return nil }
        if matchCase {
            return pattern.withUnsafeBytes { needle -> Range<Int>? in
                var from = 0
                while from <= count - n {
                    let blockEnd = min(count, from + 64 * 1_048_576 + n - 1) // Blocks, so a search can be cancelled.
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
        let lower = pattern.map(lowercased)
        let firstByte = lower[0], firstUpper = firstByte >= 0x61 && firstByte <= 0x7A ? firstByte - 0x20 : firstByte
        let last = count - n
        func next(_ byte: UInt8, from: Int) -> Int {
            guard from <= last, let hit = memchr(base + from, Int32(byte), last + 1 - from) else { return .max }
            return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
        }
        var nextLower = next(firstByte, from: 0)
        var nextUpper = firstByte == firstUpper ? Int.max : next(firstUpper, from: 0)
        var checked = 0
        while true {
            let candidate = min(nextLower, nextUpper)
            guard candidate <= last else { return nil }
            var k = 1
            while k < n && lowercased(base[candidate + k]) == lower[k] { k += 1 }
            if k == n { return candidate..<(candidate + n) }
            if candidate == nextLower { nextLower = next(firstByte, from: candidate + 1) }
            if candidate == nextUpper { nextUpper = next(firstUpper, from: candidate + 1) }
            checked += 1
            if checked % 1_000_000 == 0 && cancelled() { return nil }
        }
    }

    /// The last match, searching back in blocks.
    static func last(_ pattern: [UInt8], in base: UnsafePointer<UInt8>, count: Int, matchCase: Bool,
                     cancelled: () -> Bool = { false }) -> Range<Int>? {
        let n = pattern.count, block = 4 * 1_048_576
        guard n > 0, count >= n else { return nil }
        var blockEnd = count
        while blockEnd >= n {
            let blockStart = max(0, blockEnd - block)
            var found: Range<Int>?, from = blockStart
            while let match = first(pattern, in: base + from, count: blockEnd - from, matchCase: matchCase, cancelled: cancelled) {
                found = (from + match.lowerBound)..<(from + match.upperBound)
                from += match.lowerBound + 1
            }
            if let found { return found }
            if cancelled() || blockStart == 0 { return nil }
            blockEnd = blockStart + n - 1
        }
        return nil
    }
}
