import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Correctness and speed of the large-file storage core (Foundation only).
/// Set TIDEPAD_LARGE_MB (e.g. 500) to also time a generated file of that size.
@main struct StorageChecks {
    static var seed: UInt64 = 0x5EED
    static func random(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return bound <= 0 ? 0 : Int((seed >> 33) % UInt64(bound))
    }

    static func units(_ s: NSString, _ range: NSRange) -> [UInt16] {
        var buffer = [UInt16](repeating: 0, count: range.length)
        if range.length > 0 { s.getCharacters(&buffer, range: range) }
        return buffer
    }

    /// The full text via NSString's own primitives (swift-corelibs can't bridge subclasses to String).
    static func text(_ s: NSString) -> String {
        let all = units(s, NSRange(location: 0, length: s.length))
        return String(decoding: all, as: UTF16.self)
    }

    static func temporaryFile(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-storage-\(UUID().uuidString).txt")
        try bytes.write(to: url)
        return url
    }

    static func main() throws {
        let fragments = ["hello ", "world", "\r\n", "\n", "café ", "中文 ", "😀", "👍🏽", "x", "\t", "Ünïcödé "]
        var sample = ""
        for _ in 0..<20_000 { sample += fragments[random(fragments.count)] }

        // 1. Mapped original: random ranges match Foundation's decoding.
        for bom in [false, true] {
            let bytes = (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(sample.utf8)
            let url = try temporaryFile(bytes)
            defer { try? FileManager.default.removeItem(at: url) }
            let mapped = try MappedUTF8Text(url: url)
            let reference = sample as NSString
            precondition(mapped.utf16Count == reference.length && !mapped.isASCII, "UTF-16 length")
            for _ in 0..<3000 {
                let a = random(reference.length + 1), b = random(reference.length + 1)
                let range = NSRange(location: min(a, b), length: abs(a - b))
                var buffer = [UInt16](repeating: 0, count: range.length)
                if range.length > 0 { mapped.getCharacters(&buffer, range: range) }
                precondition(buffer == units(reference, range), "Mapped range \(range)")
            }
        }
        let ascii = try MappedUTF8Text(data: Data("plain ascii\n".utf8))
        precondition(ascii.isASCII && ascii.utf16Count == 12)
        precondition((try? MappedUTF8Text(data: Data([0x61, 0xC3, 0x28]))) == nil, "Invalid UTF-8 is rejected")
        precondition((try? MappedUTF8Text(data: Data([0xED, 0xA0, 0x80]))) == nil, "Encoded surrogates are rejected")
        let empty = try MappedUTF8Text(data: Data())
        precondition(empty.utf16Count == 0)

        // 2. Piece table: random edits mirror a plain array of UTF-16 units exactly.
        let url = try temporaryFile(Data(sample.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let table = PieceTable(original: try MappedUTF8Text(url: url))
        var reference = Array(sample.utf16)
        func boundary(_ offset: Int) -> Int {
            guard offset > 0 && offset < reference.count else { return offset }
            return (0xDC00...0xDFFF).contains(reference[offset]) ? offset - 1 : offset // Don't split a surrogate pair.
        }
        func tableUnits(_ t: PieceTable) -> [UInt16] {
            var buffer = [UInt16](repeating: 0, count: t.length)
            if t.length > 0 { t.getCharacters(&buffer, range: NSRange(location: 0, length: t.length)) }
            return buffer
        }
        var snapshots: [(PieceTableString, [UInt16])] = []
        for step in 0..<4000 {
            let a = boundary(random(reference.count + 1)), b = boundary(random(reference.count + 1))
            var range = NSRange(location: min(a, b), length: abs(a - b))
            if random(3) == 0 { range.length = 0 }                   // insertion
            if random(4) == 0 { range.length = min(range.length, 3) } // small deletion
            range.length = boundary(NSMaxRange(range)) - range.location
            let text = random(3) == 0 ? "" : (0..<(1 + random(3))).map { _ in fragments[random(fragments.count)] }.joined()
            table.replace(range, with: Array(text.utf16))
            reference.replaceSubrange(range.location..<NSMaxRange(range), with: Array(text.utf16))
            precondition(table.length == reference.count, "Length after edit \(step)")
            if step % 50 == 0 {
                precondition(tableUnits(table) == reference, "Content after edit \(step)")
                snapshots.append((PieceTableString(table: table).copy() as! PieceTableString, reference))
            }
            // Typing: consecutive single-character inserts coalesce into one piece.
            if step == 2000 {
                let before = table.pieces.count, at = boundary(reference.count / 2)
                for (k, unit) in "typing".utf16.enumerated() {
                    table.replace(NSRange(location: at + k, length: 0), with: [unit])
                    reference.insert(unit, at: at + k)
                }
                precondition(table.pieces.count <= before + 2, "Typing coalesces: \(before) → \(table.pieces.count)")
            }
        }
        for (snapshot, expected) in snapshots {
            precondition(units(snapshot, NSRange(location: 0, length: snapshot.length)) == expected, "Snapshots don't change with later edits")
        }
        precondition(tableUnits(table) == reference, "Final content")
        let referenceString = String(decoding: reference, as: UTF16.self)

        // 3. The NSString subclass behaves like any NSString.
        let string = PieceTableString(table: table)
        let referenceNS = NSString(characters: reference, length: reference.count)
        precondition(string.length == referenceNS.length && text(string) == referenceString, "Full text")
        precondition(string.isEqual(to: referenceString), "isEqual")
        #if !os(Linux)
        precondition(String(string) == referenceString, "Bridging to String")
        #endif
        let middle = NSRange(location: boundary(reference.count / 3), length: 0)
        precondition(string.lineRange(for: middle) == referenceNS.lineRange(for: middle), "lineRange")
        precondition(string.range(of: "typing") == referenceNS.range(of: "typing"), "range(of:)")

        // 4. Streaming save round-trips (original pieces copied as bytes, added text transcoded).
        for bom in [false, true] {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-save-\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            try table.writeUTF8(to: handle, byteOrderMark: bom)
            try handle.close()
            let saved = try Data(contentsOf: out)
            try? FileManager.default.removeItem(at: out)
            precondition(saved == (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(referenceString.utf8), "Save round-trip")
        }
        print("Storage checks passed: mapped UTF-8 (BOM, invalid input), 4,000 random edits, snapshots, NSString behaviour, streaming save.")

        if let megabytes = Int(ProcessInfo.processInfo.environment["TIDEPAD_LARGE_MB"] ?? ""), megabytes > 0 {
            try largeFileTimings(megabytes: megabytes)
        }
    }

    static func residentMB() -> Int {
        #if os(Linux)
        let status = (try? String(contentsOfFile: "/proc/self/status", encoding: .utf8)) ?? ""
        let line = status.split(separator: "\n").first { $0.hasPrefix("VmRSS:") } ?? ""
        return (Int(line.split(separator: " ").dropFirst().first ?? "0") ?? 0) / 1024
        #else
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : 0
        #endif
    }

    static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        let value = try body()
        print(String(format: "  %-44@ %8.1f ms   RSS %5d MB", label as NSString, Date().timeIntervalSince(start) * 1000, residentMB()))
        return value
    }

    static func largeFileTimings(megabytes: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-large-\(megabytes)mb.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            print("Generating \(megabytes) MB test file…")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            var line = 0
            let block = (0..<10_000).map { k in "\(k): The quick brown fox jumps over the lazy dog — café 中文 \(k * 31)\n" }.joined()
            let blockData = Data(block.utf8)
            while line * blockData.count < megabytes * 1_048_576 { try handle.write(contentsOf: blockData); line += 1 }
            try handle.close()
        }
        print("Large file: \(megabytes) MB (\(url.path)), RSS at start \(residentMB()) MB")
        let mapped = try time("open (map + validating scan)") { try MappedUTF8Text(url: url) }
        let table = PieceTable(original: mapped)
        let string = PieceTableString(table: table)
        print("  UTF-16 length: \(string.length)")
        var buffer = [UInt16](repeating: 0, count: 200_000)
        time("read 200k units at start/middle/end") {
            for location in [0, string.length / 2, string.length - buffer.count] {
                string.getCharacters(&buffer, range: NSRange(location: location, length: buffer.count))
            }
        }
        time("1,000 random character(at:)") { for _ in 0..<1000 { _ = string.character(at: random(string.length)) } }
        time("type 1,000 characters at the middle") {
            let at = string.length / 2
            for k in 0..<1000 { table.replace(NSRange(location: at + k, length: 0), with: [0x61]) }
        }
        time("1,000 scattered edits") {
            for _ in 0..<1000 {
                let at = random(string.length - 10)
                table.replace(NSRange(location: at, length: random(5)), with: Array("edit".utf16))
            }
        }
        time("delete 100 MB-ish range in the middle") {
            table.replace(NSRange(location: string.length / 4, length: string.length / 5), with: [])
        }
        _ = time("snapshot (what bridging to String costs)") { string.copy() }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-large-saved.txt")
        try time("save (streamed)") {
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            try table.writeUTF8(to: handle)
            try handle.close()
        }
        try? FileManager.default.removeItem(at: out)
        print("  pieces: \(table.pieces.count), added buffer: \(table.added.count) units")
    }
}
