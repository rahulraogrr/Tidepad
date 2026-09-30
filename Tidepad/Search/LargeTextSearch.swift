import Foundation

/// Find and replace in a large file (LargeTextBuffer), run in the background on a snapshot.
///
/// Plain text is found in the bytes (LargeTextBuffer.find: memchr and memmem). Regular expressions,
/// Whole word, and ignoring case in non-ASCII text use NSRegularExpression, with the same expression
/// as the normal editor (SearchEngine.expression), over the text in chunks: about 4 MB at a time,
/// cut at a line break, each decoded into an NSString. Chunks overlap by 64 KB, so a match across a
/// cut is still found whole, and each carries up to 4 KB of the text on either side, so ^, $ and
/// look-arounds see what comes before and after (the search range leaves it out:
/// withTransparentBounds, withoutAnchoringBounds). Match positions, in UTF-16 in the chunk, are turned back into byte
/// offsets by walking the chunk's UTF-8.
///
/// Limits: a match found this way can't be longer than 64 KB, and look-arounds see at most 4 KB away.
struct LargeTextSearch: @unchecked Sendable {
    enum Matcher {
        case bytes([UInt8], matchCase: Bool)
        case expression(NSRegularExpression)
    }
    /// A match: its bytes, and for an expression the result and the chunk it was found in (for
    /// replacement templates like $1).
    struct Match {
        let range: Range<Int>
        let result: NSTextCheckingResult?
        let text: NSString?
    }
    typealias Edit = (range: Range<Int>, bytes: [UInt8])

    let query: SearchQuery
    let matcher: Matcher
    /// Chunk sizes, in bytes (smaller in checks, to exercise the cuts).
    let chunkSize: Int
    let overlap: Int
    let context: Int

    init(_ query: SearchQuery, chunkSize: Int = 4 << 20, overlap: Int = 64 << 10, context: Int = 4 << 10) throws {
        guard !query.text.isEmpty else { throw SearchFailure.empty }
        precondition(chunkSize >= 4 * overlap && overlap > 0)
        self.query = query
        self.chunkSize = chunkSize
        self.overlap = overlap
        self.context = context
        let literal = query.mode == .extended ? try SearchEngine.decode(query.text) : query.text
        if let expression = try SearchEngine.expression(for: query, literal: literal) {
            matcher = .expression(expression)
        } else if !query.matchCase && literal.utf8.contains(where: { $0 >= 0x80 }) {
            // The byte search only folds ASCII letters; é and É, or Greek and Cyrillic, need Unicode folding.
            matcher = .expression(try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: literal),
                                                          options: [.caseInsensitive]))
        } else {
            matcher = .bytes(Array(literal.utf8), matchCase: query.matchCase)
        }
    }

    /// Whether this search uses NSRegularExpression (false: the byte search).
    var usesExpression: Bool { if case .expression = matcher { return true }; return false }

    // MARK: Find Next and Previous

    /// The next match after `offset` (or the previous one, ending at or before it), wrapping round
    /// when `wrap`. `excluding`: an empty match to step over (the one just found, where the caret is).
    func next(in buffer: LargeTextBuffer, from offset: Int, backwards: Bool = false, wrap: Bool = true,
              excluding: Range<Int>? = nil, cancelled: () -> Bool = { false }) -> Range<Int>? {
        let offset = min(max(buffer.contentStart, offset), buffer.count)
        switch matcher {
        case .bytes(let pattern, let matchCase):
            return buffer.find(pattern, from: offset, backwards: backwards, matchCase: matchCase, wrap: wrap, cancelled: cancelled)
        case .expression(let expression):
            let before = buffer.contentStart..<offset, after = offset..<buffer.count
            if backwards {
                if let match = lastMatch(expression, in: buffer, range: before, excluding: excluding, cancelled: cancelled) { return match }
                return wrap && !cancelled() ? lastMatch(expression, in: buffer, range: after, excluding: excluding, cancelled: cancelled) : nil
            }
            if let match = firstMatch(expression, in: buffer, range: after, excluding: excluding, cancelled: cancelled) { return match }
            return wrap && !cancelled() ? firstMatch(expression, in: buffer, range: before, excluding: excluding, cancelled: cancelled) : nil
        }
    }

    private func firstMatch(_ expression: NSRegularExpression, in buffer: LargeTextBuffer, range: Range<Int>,
                            excluding: Range<Int>?, cancelled: () -> Bool) -> Range<Int>? {
        var found: Range<Int>?
        forEachExpressionMatch(expression, in: buffer, range: range, cancelled: cancelled) { match in
            if match.range == excluding { return true }
            found = match.range
            return false
        }
        return found
    }

    /// The last match in `range`: chunks from the end back, each searched forward.
    private func lastMatch(_ expression: NSRegularExpression, in buffer: LargeTextBuffer, range: Range<Int>,
                           excluding: Range<Int>?, cancelled: () -> Bool) -> Range<Int>? {
        var end = range.upperBound
        while end > range.lowerBound && !cancelled() {
            var start = max(range.lowerBound, end - chunkSize)
            if start > range.lowerBound {
                start = lineStart(in: buffer, from: start, before: start + chunkSize / 2) ?? characterStart(in: buffer, at: start, floor: range.lowerBound)
            }
            var found: Range<Int>?
            forEachExpressionMatch(expression, in: buffer, range: start..<end, cancelled: cancelled) { match in
                if match.range != excluding { found = match.range }
                return true
            }
            if let found { return found }
            if start == range.lowerBound { return nil }
            end = start + overlap // Overlapping, for a match across the cut.
        }
        return nil
    }

    // MARK: All matches

    /// Calls `visit` with each match in `range`, in order; stops when it returns false.
    func forEachMatch(in buffer: LargeTextBuffer, range: Range<Int>, cancelled: () -> Bool = { false },
                      _ visit: (Match) -> Bool) {
        let lower = min(max(buffer.contentStart, range.lowerBound), buffer.count)
        let range = lower..<min(buffer.count, max(lower, range.upperBound))
        switch matcher {
        case .bytes(let pattern, let matchCase):
            var from = range.lowerBound
            while !cancelled(), let found = buffer.firstMatch(pattern, in: from..<range.upperBound, matchCase: matchCase, cancelled: cancelled) {
                if !visit(Match(range: found, result: nil, text: nil)) { return }
                from = found.upperBound
            }
        case .expression(let expression):
            forEachExpressionMatch(expression, in: buffer, range: range, cancelled: cancelled, visit)
        }
    }

    /// The number of matches (Count).
    func count(in buffer: LargeTextBuffer, range: Range<Int>? = nil, cancelled: () -> Bool = { false }) -> Int {
        var total = 0
        forEachMatch(in: buffer, range: range ?? buffer.contentStart..<buffer.count, cancelled: cancelled) { _ in total += 1; return true }
        return total
    }

    // MARK: Replacing

    /// Every match in `range` and the bytes to put in its place (Replace All). Throws when there are
    /// more than `limit`, as the normal editor does, before anything is changed.
    func replacements(in buffer: LargeTextBuffer, range: Range<Int>, template: String, limit: Int = 100_000,
                      cancelled: () -> Bool = { false }) throws -> [Edit] {
        let literal = try replacementLiteral(template)
        let fixed = Array(literal.utf8)
        var edits: [Edit] = [], overflow = false
        forEachMatch(in: buffer, range: range, cancelled: cancelled) { match in
            if edits.count == limit { overflow = true; return false }
            edits.append((match.range, replacement(for: match, literal: literal, fixed: fixed)))
            return true
        }
        if cancelled() { throw CancellationError() }
        if overflow { throw SearchFailure.tooManyReplacements }
        return edits
    }

    /// The bytes to replace the selection with, if the selection is exactly a match (Replace).
    func replacement(forSelection selection: Range<Int>, in buffer: LargeTextBuffer, template: String,
                     cancelled: () -> Bool = { false }) throws -> [UInt8]? {
        let literal = try replacementLiteral(template)
        var found: [UInt8]?
        forEachMatch(in: buffer, range: selection, cancelled: cancelled) { match in
            guard match.range == selection else { return true }
            found = replacement(for: match, literal: literal, fixed: Array(literal.utf8))
            return false
        }
        return found
    }

    private func replacementLiteral(_ template: String) throws -> String {
        query.mode == .extended ? try SearchEngine.decode(template) : template
    }

    /// In regular-expression mode the replacement is a template ($1, \\$); otherwise it's the text itself.
    private func replacement(for match: Match, literal: String, fixed: [UInt8]) -> [UInt8] {
        guard query.mode == .regex, case .expression(let expression) = matcher, let result = match.result, let text = match.text else { return fixed }
        return Array(expression.replacementString(for: result, in: text as String, offset: 0, template: literal).utf8)
    }

    // MARK: Chunks

    /// Every match of an expression in `range`, chunk by chunk. A chunk's matches are taken up to
    /// `overlap` before its end; the next chunk starts there (or after the last match taken), so a
    /// match up to `overlap` long that crosses the cut is found whole in the next one.
    private func forEachExpressionMatch(_ expression: NSRegularExpression, in buffer: LargeTextBuffer, range: Range<Int>,
                                        cancelled: () -> Bool, _ visit: (Match) -> Bool) {
        var start = range.lowerBound
        while start < range.upperBound {
            if cancelled() { return }
            let end = cut(buffer, from: start, limit: range.upperBound)
            let last = end == range.upperBound, accept = last ? end : end - overlap
            let chunk = LargeTextChunk(buffer, contextStart(in: buffer, before: start)..<contextEnd(in: buffer, after: end))
            let from = chunk.unitOffset(ofByte: start), to = chunk.unitOffset(ofByte: end)
            var taken = start, stopped = false
            expression.enumerateMatches(in: chunk.text as String, options: [.withTransparentBounds, .withoutAnchoringBounds],
                                        range: NSRange(location: from, length: to - from)) { result, _, stop in
                guard let result else { return }
                if cancelled() { stopped = true; stop.pointee = true; return }
                let lower = chunk.byteOffset(ofUnit: result.range.location)
                guard lower < accept || last else { stop.pointee = true; return }
                let upper = chunk.byteOffset(ofUnit: NSMaxRange(result.range))
                taken = upper
                if !visit(Match(range: lower..<upper, result: result, text: chunk.text)) { stopped = true; stop.pointee = true }
            }
            if stopped { return }
            start = max(accept, taken)
        }
    }

    /// Where a chunk from `start` ends: at a line start in its second half if there is one (so lines
    /// are rarely cut), otherwise between two characters.
    private func cut(_ buffer: LargeTextBuffer, from start: Int, limit: Int) -> Int {
        let target = start + chunkSize
        guard target < limit else { return limit }
        return lineStart(in: buffer, from: start + chunkSize / 2, before: target)
            ?? characterStart(in: buffer, at: target, floor: start + chunkSize / 2)
    }

    /// The first line start after a line break in `from..<before`.
    private func lineStart(in buffer: LargeTextBuffer, from: Int, before: Int) -> Int? {
        var found: Int?
        buffer.forEachSegment(in: from..<before) { offset, bytes, count in
            guard let hit = memchr(bytes, Int32(buffer.breakByte), count) else { return true }
            found = offset + (UnsafeRawPointer(hit) - UnsafeRawPointer(bytes)) + 1
            return false
        }
        return found.flatMap { $0 < before ? $0 : nil }
    }

    /// `offset`, or the start of the character it's inside.
    private func characterStart(in buffer: LargeTextBuffer, at offset: Int, floor: Int) -> Int {
        var offset = offset
        while offset > floor && offset < buffer.count && buffer.byte(at: offset) & 0xC0 == 0x80 { offset -= 1 }
        return offset
    }

    /// Where a chunk's text ends: up to `context` bytes after its search range, on a character (so $
    /// and look-aheads at the range's end see what follows, as in the whole text).
    private func contextEnd(in buffer: LargeTextBuffer, after end: Int) -> Int {
        var offset = min(buffer.count, end + context)
        while offset > end && offset < buffer.count && buffer.byte(at: offset) & 0xC0 == 0x80 { offset -= 1 }
        return offset
    }

    /// Where a chunk's text starts: up to `context` bytes before its search range, on a character.
    private func contextStart(in buffer: LargeTextBuffer, before start: Int) -> Int {
        var offset = max(buffer.contentStart, start - context)
        while offset < start && buffer.byte(at: offset) & 0xC0 == 0x80 { offset += 1 }
        return offset
    }
}

/// Some of a large file's text as an NSString, for NSRegularExpression, with a way between its UTF-16
/// offsets and byte offsets in the file.
final class LargeTextChunk {
    let text: NSString
    /// The byte offset of the text's start.
    let start: Int
    private let bytes: [UInt8]
    private let isASCII: Bool
    /// A position walked to: UTF-16 units and bytes from the start. Offsets asked for mostly increase.
    private var unit = 0, byte = 0

    init(_ buffer: LargeTextBuffer, _ range: Range<Int>) {
        bytes = buffer.bytes(in: range)
        start = range.lowerBound
        // Foundation decodes valid UTF-8 quickly; it would drop a U+FEFF at the start, so that case (and
        // bytes that aren't UTF-8) are decoded here, one unit per invalid byte, as the walk counts them.
        if !bytes.starts(with: [0xEF, 0xBB, 0xBF]), let decoded = NSString(bytes: bytes, length: bytes.count, encoding: String.Encoding.utf8.rawValue) {
            text = decoded
        } else {
            text = Self.decode(bytes)
        }
        // Units and bytes are equal only when every character is one byte.
        isASCII = text.length == bytes.count
    }

    /// The byte offset (in the file) of a UTF-16 offset in the text.
    func byteOffset(ofUnit target: Int) -> Int {
        if isASCII { return start + target }
        if target < unit { unit = 0; byte = 0 }
        bytes.withUnsafeBufferPointer { buffer in
            while unit < target && byte < buffer.count {
                let step = Self.sequence(buffer, at: byte)
                unit += step.units
                byte += step.bytes
            }
        }
        return start + byte
    }

    /// The UTF-16 offset in the text of a byte offset in the file (on a character).
    func unitOffset(ofByte target: Int) -> Int {
        if isASCII { return target - start }
        if target - start < byte { unit = 0; byte = 0 }
        bytes.withUnsafeBufferPointer { buffer in
            while byte < target - start && byte < buffer.count {
                let step = Self.sequence(buffer, at: byte)
                unit += step.units
                byte += step.bytes
            }
        }
        return unit
    }

    /// The UTF-8 sequence at `index`: its length in bytes, and in UTF-16 units. A byte that doesn't
    /// start a valid sequence is one byte and one unit (U+FFFD).
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

    /// UTF-8 to UTF-16 with each invalid byte as U+FFFD, matching `sequence`.
    private static func decode(_ bytes: [UInt8]) -> NSString {
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
        return NSString(characters: units, length: units.count)
    }
}
