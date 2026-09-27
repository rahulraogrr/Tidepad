import Foundation

/// Editable text over an unchanged original: the document is a list of pieces, each pointing into
/// either the memory-mapped original file or an append-only buffer of added text. An edit splits at
/// most two pieces and inserts one; no text is moved, whatever the document's size. All offsets are
/// UTF-16 code units, matching NSString and TextKit.
final class PieceTable: @unchecked Sendable {
    enum Source: UInt8 { case original, added }

    struct Piece: Equatable {
        var source: Source
        var start: Int
        var length: Int
    }

    let original: MappedUTF8Text
    private(set) var added: [UInt16] = []
    private(set) var pieces: [Piece]
    /// ends[k] is the document offset just after pieces[k] (prefix sums, for binary search).
    private var ends: [Int]
    /// NSString may be read from background threads; edits happen on the main thread.
    private let lock = NSLock()

    /// Snapshots are read-only.
    let isFrozen: Bool

    init(original: MappedUTF8Text) {
        self.original = original
        pieces = original.utf16Count > 0 ? [Piece(source: .original, start: 0, length: original.utf16Count)] : []
        ends = pieces.map(\.length)
        isFrozen = false
    }

    private init(original: MappedUTF8Text, pieces: [Piece], ends: [Int], added: [UInt16]) {
        self.original = original
        self.pieces = pieces
        self.ends = ends
        self.added = added
        isFrozen = true
    }

    /// An immutable copy in O(pieces): it shares the mapped original, and the added buffer is
    /// append-only, so existing pieces stay valid (Swift arrays copy on write).
    func snapshot() -> PieceTable {
        lock.withLock { PieceTable(original: original, pieces: pieces, ends: ends, added: added) }
    }

    var length: Int { lock.withLock { ends.last ?? 0 } }

    /// Index of the piece containing `offset` (the first piece whose end is past it).
    private func pieceIndex(containing offset: Int) -> Int {
        var low = 0, high = ends.count
        while low < high {
            let middle = (low + high) / 2
            if ends[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    func character(at index: Int) -> UInt16 {
        var unit: UInt16 = 0
        getCharacters(&unit, range: NSRange(location: index, length: 1))
        return unit
    }

    func getCharacters(_ buffer: UnsafeMutablePointer<UInt16>, range: NSRange) {
        lock.lock(); defer { lock.unlock() }
        precondition(range.location >= 0 && NSMaxRange(range) <= (ends.last ?? 0), "Range out of bounds")
        var offset = range.location, remaining = range.length, written = 0
        var k = pieceIndex(containing: offset)
        while remaining > 0 {
            let piece = pieces[k]
            let pieceStart = ends[k] - piece.length
            let within = offset - pieceStart
            let count = min(remaining, piece.length - within)
            switch piece.source {
            case .original:
                original.getCharacters(buffer + written, range: NSRange(location: piece.start + within, length: count))
            case .added:
                added.withUnsafeBufferPointer { source in
                    (buffer + written).update(from: source.baseAddress! + piece.start + within, count: count)
                }
            }
            written += count; offset += count; remaining -= count; k += 1
        }
    }

    /// Replaces `range` with `units`. Consecutive typing extends the last added piece instead of
    /// creating a new one per keystroke.
    func replace(_ range: NSRange, with units: [UInt16]) {
        precondition(!isFrozen, "Snapshots are read-only")
        lock.lock(); defer { lock.unlock() }
        let total = ends.last ?? 0
        precondition(range.location >= 0 && NSMaxRange(range) <= total, "Range out of bounds")
        guard range.length > 0 || !units.isEmpty else { return }

        if range.length == 0 && !units.isEmpty && range.location > 0 {
            let k = pieceIndex(containing: range.location - 1)
            if ends[k] == range.location && pieces[k].source == .added && pieces[k].start + pieces[k].length == added.count {
                added.append(contentsOf: units)
                pieces[k].length += units.count
                for j in k..<ends.count { ends[j] += units.count }
                return
            }
        }

        let first = pieceIndex(containing: range.location)
        let lastOffset = range.length > 0 ? NSMaxRange(range) - 1 : range.location
        let last = min(pieceIndex(containing: lastOffset), pieces.count - 1)
        var replacement: [Piece] = []
        var replaceRange = first..<first // Pieces being replaced.
        if first < pieces.count {
            let firstStart = ends[first] - pieces[first].length
            if range.location > firstStart {
                replacement.append(Piece(source: pieces[first].source, start: pieces[first].start, length: range.location - firstStart))
            }
            if !units.isEmpty {
                replacement.append(Piece(source: .added, start: added.count, length: units.count))
                added.append(contentsOf: units)
            }
            let lastEnd = ends[last]
            let end = NSMaxRange(range)
            if range.length == 0 {
                // Insertion inside `first`: keep its remainder after the new text.
                if range.location >= firstStart {
                    let consumed = range.location - firstStart
                    replacement.append(Piece(source: pieces[first].source, start: pieces[first].start + consumed,
                                             length: pieces[first].length - consumed))
                }
                replaceRange = first..<(first + 1)
            } else {
                if end < lastEnd {
                    let lastStart = lastEnd - pieces[last].length
                    let consumed = end - lastStart
                    replacement.append(Piece(source: pieces[last].source, start: pieces[last].start + consumed,
                                             length: pieces[last].length - consumed))
                }
                replaceRange = first..<(last + 1)
            }
        } else {
            // Appending at the very end.
            replacement.append(Piece(source: .added, start: added.count, length: units.count))
            added.append(contentsOf: units)
        }
        replacement.removeAll { $0.length == 0 }
        pieces.replaceSubrange(replaceRange, with: replacement)
        // Recompute prefix sums from the first changed piece.
        var running = replaceRange.lowerBound > 0 ? ends[replaceRange.lowerBound - 1] : 0
        ends.removeSubrange(replaceRange.lowerBound...)
        for piece in pieces[replaceRange.lowerBound...] { running += piece.length; ends.append(running) }
    }

    /// Streams the document as UTF-8 to `handle`: original pieces are copied as bytes straight from
    /// the mapped file; added text is transcoded. The whole document is never held in memory.
    func writeUTF8(to handle: FileHandle, byteOrderMark: Bool = false) throws {
        let (snapshotPieces, snapshotAdded) = lock.withLock { (pieces, added) }
        if byteOrderMark { try handle.write(contentsOf: Data([0xEF, 0xBB, 0xBF])) }
        let chunk = 1 << 20
        for piece in snapshotPieces {
            if piece.source == .original,
               let from = original.byteOffset(forUTF16: piece.start),
               let to = original.byteOffset(forUTF16: piece.start + piece.length) {
                var offset = from
                while offset < to {
                    let next = min(to, offset + chunk)
                    try handle.write(contentsOf: original.data[offset..<next])
                    offset = next
                }
                continue
            }
            var offset = 0
            var units = [UInt16](repeating: 0, count: min(chunk, piece.length))
            while offset < piece.length {
                var count = min(chunk, piece.length - offset)
                units.withUnsafeMutableBufferPointer { buffer in
                    switch piece.source {
                    case .original: original.getCharacters(buffer.baseAddress!, range: NSRange(location: piece.start + offset, length: count))
                    case .added: snapshotAdded.withUnsafeBufferPointer { source in
                        buffer.baseAddress!.update(from: source.baseAddress! + piece.start + offset, count: count)
                    }
                    }
                }
                // Don't split a surrogate pair across chunks.
                if offset + count < piece.length, (0xD800...0xDBFF).contains(units[count - 1]) { count -= 1 }
                let text = String(decoding: units[0..<count], as: UTF16.self)
                try handle.write(contentsOf: Data(text.utf8))
                offset += count
            }
        }
    }
}
