import Foundation

/// A file's original contents, memory-mapped with `Data(contentsOf:options: .alwaysMapped)` so macOS
/// pages bytes in only where they're read, and exposed as UTF-16 code units — the unit NSString and
/// TextKit index by. Nothing is decoded up front except one validating scan that records a
/// checkpoint (UTF-16 offset ↔ byte offset) every `checkpointStride` bytes.
///
/// Important: never write to the mapped file in place. Saves go to a new file that replaces it
/// (TextFileService does this), which keeps this mapping valid until it's released.
final class MappedUTF8Text: @unchecked Sendable {
    enum Failure: Error { case invalidUTF8(byteOffset: Int) }

    static let checkpointStride = 4096

    let data: Data
    /// Bytes skipped at the start (a UTF-8 byte order mark).
    let byteBase: Int
    let utf16Count: Int
    /// All bytes below 0x80: UTF-16 offsets equal byte offsets and no decoding is needed.
    let isASCII: Bool
    private let checkpointUTF16: [Int]
    private let checkpointByte: [Int]
    /// Last decoded position, so sequential reads (what TextKit mostly does) don't search.
    private var cacheUTF16 = 0
    private var cacheByte = 0
    /// Guards the cache; TextKit may read from background threads (e.g. spell checking, printing).
    private let lock = NSLock()

    /// An empty text (no file).
    static let empty = try! MappedUTF8Text(data: Data())

    convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        self.data = data
        let hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        byteBase = hasBOM ? 3 : 0
        var units = 0, ascii = true
        var cpU: [Int] = [], cpB: [Int] = []
        let stride = Self.checkpointStride
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let n = raw.count
            var i = hasBOM ? 3 : 0
            var nextCheckpoint = i
            while i < n {
                if i >= nextCheckpoint { cpU.append(units); cpB.append(i); nextCheckpoint = i + stride }
                // Fast path: eight ASCII bytes at a time.
                while i + 8 <= n && i + 8 <= nextCheckpoint {
                    if (base + i).loadUnaligned(as: UInt64.self) & 0x8080_8080_8080_8080 != 0 { break }
                    i += 8; units += 8
                }
                if i >= n || i >= nextCheckpoint { continue }
                let lead = bytes[i]
                if lead < 0x80 { i += 1; units += 1; continue }
                ascii = false
                guard let (scalar, length) = Self.decode(bytes, at: i, count: n) else { throw Failure.invalidUTF8(byteOffset: i) }
                i += length
                units += scalar > 0xFFFF ? 2 : 1
            }
        }
        utf16Count = units
        isASCII = ascii
        checkpointUTF16 = cpU
        checkpointByte = cpB
        cacheByte = byteBase
    }

    /// Decodes one well-formed UTF-8 scalar (rejecting overlongs, surrogates and out-of-range values).
    @inline(__always)
    static func decode(_ bytes: UnsafePointer<UInt8>, at i: Int, count n: Int) -> (UInt32, Int)? {
        let b0 = UInt32(bytes[i])
        if b0 < 0x80 { return (b0, 1) }
        func cont(_ k: Int) -> UInt32? {
            guard i + k < n else { return nil }
            let b = UInt32(bytes[i + k])
            return b & 0xC0 == 0x80 ? b & 0x3F : nil
        }
        if b0 & 0xE0 == 0xC0 {
            guard let c1 = cont(1) else { return nil }
            let v = (b0 & 0x1F) << 6 | c1
            return v >= 0x80 ? (v, 2) : nil
        }
        if b0 & 0xF0 == 0xE0 {
            guard let c1 = cont(1), let c2 = cont(2) else { return nil }
            let v = (b0 & 0x0F) << 12 | c1 << 6 | c2
            return v >= 0x800 && !(0xD800...0xDFFF).contains(v) ? (v, 3) : nil
        }
        if b0 & 0xF8 == 0xF0 {
            guard let c1 = cont(1), let c2 = cont(2), let c3 = cont(3) else { return nil }
            let v = (b0 & 0x07) << 18 | c1 << 12 | c2 << 6 | c3
            return (0x10000...0x10FFFF).contains(v) ? (v, 4) : nil
        }
        return nil
    }

    /// Copies `range` (UTF-16 units) into `buffer`.
    func getCharacters(_ buffer: UnsafeMutablePointer<UInt16>, range: NSRange) {
        guard range.length > 0 else { return }
        precondition(range.location >= 0 && NSMaxRange(range) <= utf16Count, "Range out of bounds")
        lock.lock(); defer { lock.unlock() }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            if isASCII {
                let source = bytes + byteBase + range.location
                for k in 0..<range.length { buffer[k] = UInt16(source[k]) }
                return
            }
            var (u, i) = start(atOrBefore: range.location)
            var written = 0
            let end = NSMaxRange(range), n = raw.count
            while u < end {
                let (scalar, length) = Self.decode(bytes, at: i, count: n)!
                if scalar > 0xFFFF {
                    let v = scalar - 0x10000
                    let high = UInt16(0xD800 + (v >> 10)), low = UInt16(0xDC00 + (v & 0x3FF))
                    if u >= range.location { buffer[written] = high; written += 1 }
                    if u + 1 >= range.location && u + 1 < end { buffer[written] = low; written += 1 }
                    u += 2
                } else {
                    if u >= range.location { buffer[written] = UInt16(scalar); written += 1 }
                    u += 1
                }
                i += length
            }
            cacheUTF16 = u; cacheByte = i
        }
    }

    /// The byte offset of a UTF-16 offset that falls on a scalar boundary; nil inside a surrogate pair.
    func byteOffset(forUTF16 offset: Int) -> Int? {
        if isASCII { return byteBase + offset }
        if offset == utf16Count { return data.count }
        lock.lock(); defer { lock.unlock() }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let bytes = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var (u, i) = start(atOrBefore: offset)
            while u < offset {
                let (scalar, length) = Self.decode(bytes, at: i, count: raw.count)!
                u += scalar > 0xFFFF ? 2 : 1
                i += length
            }
            return u == offset ? i : nil
        }
    }

    /// The nearest known (UTF-16 offset, byte offset) at or before `offset`: the cache or a checkpoint.
    private func start(atOrBefore offset: Int) -> (Int, Int) {
        if cacheUTF16 <= offset && offset - cacheUTF16 < Self.checkpointStride { return (cacheUTF16, cacheByte) }
        var low = 0, high = checkpointUTF16.count
        while low < high {
            let middle = (low + high) / 2
            if checkpointUTF16[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        let k = max(0, low - 1)
        return checkpointUTF16.isEmpty ? (0, byteBase) : (checkpointUTF16[k], checkpointByte[k])
    }
}
