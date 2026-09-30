import AppKit
import Darwin

/// Large-file spike (see claude/large-file-view-plan.md in the TidePad project). Answers the three
/// open questions before the large-file view is built, with measurements against the targets:
///
///   Tests/run-large-file-spike.sh index      line index: newline scan speed (bytes and UTF-16), memory
///   Tests/run-large-file-spike.sh textkit2   TextKit 2 with our own NSTextContentManager over the piece
///                                            table: open, jump, scroll, elements created, memory
///   Tests/run-large-file-spike.sh clone      APFS clone: does it protect a memory-mapped file from being
///                                            truncated by another app (which otherwise crashes with SIGBUS)?
///   Tests/run-large-file-spike.sh scroll [--height 1e9]
///                                            a very tall view, left open to check text stays sharp
///
/// Options: --mb N (default 500), --file path (default: a generated file in the temporary folder).
@main struct LargeFileSpike {
    static let arguments = CommandLine.arguments
    static func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    static var results: [String] = []

    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : 0
    }

    /// Memory the app really owns (what Activity Monitor shows as Memory): unlike RSS, it leaves out the
    /// file's own pages, which macOS can drop and re-read at any time.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : 0
    }

    /// Times `body` and prints it with the target it must meet (nil: informational).
    @discardableResult
    static func measure<T>(_ label: String, target milliseconds: Double? = nil, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        report(label, elapsed, target: milliseconds)
        return value
    }

    static func report(_ label: String, _ milliseconds: Double, target: Double?) {
        let verdict = target.map { milliseconds <= $0 ? "PASS (< \(Int($0)) ms)" : "FAIL (target \(Int($0)) ms)" } ?? ""
        let line = String(format: "%-52@ %10.2f ms  memory %5d MB (RSS %5d)  %@", label as NSString, milliseconds, footprintMB(), residentMB(), verdict as NSString)
        print(line)
        results.append(line)
    }

    static func testFile() throws -> URL {
        let megabytes = Int(value("--mb") ?? "500") ?? 500
        let url = value("--file").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-large-\(megabytes)mb.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            print("Generating \(megabytes) MB test file at \(url.path)…")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            let block = Data((0..<10_000).map { k in
                "\(k): SELECT id, name FROM trades WHERE qty > \(k * 31) AND book = 'café 中文' -- line \(k)\n"
            }.joined().utf8)
            var written = 0
            while written < megabytes * 1_048_576 { try handle.write(contentsOf: block); written += block.count }
            try handle.close()
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("File: \(url.path) (\(size / 1_048_576) MB)")
        return url
    }

    @MainActor static func main() throws {
        let experiment = arguments.dropFirst().first { !$0.hasPrefix("-") && Double($0) == nil } ?? "index"
        print("Tidepad large-file spike: \(experiment) · RSS at start \(residentMB()) MB")
        switch experiment {
        case "index": try indexExperiment()
        case "textkit2": try textKit2Experiment()
        case "coretext": try coreTextExperiment()
        case "clone": try cloneExperiment()
        case "clone-control": try cloneControl()
        case "scroll": scrollExperiment()
        default: print("Unknown experiment \(experiment). Use index, textkit2, clone or scroll.")
        }
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-spike-\(experiment).txt")
        try? (results.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        print("Report: \(report.path)")
    }

    // MARK: 1. Line index

    /// How fast can the start of every line be found, and what does storing them cost?
    static func indexExperiment() throws {
        let url = try testFile()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        for pass in ["first pass (cold if the file isn't cached)", "second pass (warm)"] {
            var lines = 0
            measure("memchr newline scan, bytes, \(pass)", target: 500) {
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var cursor = base, remaining = raw.count
                    while remaining > 0, let hit = memchr(cursor, 0x0A, remaining) {
                        lines += 1
                        let next = UnsafeRawPointer(hit) + 1
                        remaining -= next - cursor
                        cursor = next
                    }
                }
            }
            print("  lines: \(lines)")
        }
        var sparse: [Int] = []
        measure("sparse index (every 64th line start, bytes)") {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var cursor = base, remaining = raw.count, line = 0
                sparse.append(0)
                while remaining > 0, let hit = memchr(cursor, 0x0A, remaining) {
                    line += 1
                    let next = UnsafeRawPointer(hit) + 1
                    if line % 64 == 0 { sparse.append(next - base) }
                    remaining -= next - cursor
                    cursor = next
                }
            }
        }
        print("  sparse entries: \(sparse.count) · \(sparse.count * 8 / 1024) KB (full index would be \(sparse.count * 64 * 8 / 1_048_576) MB)")
        let text = try MappedUTF8Text(url: url)
        let table = PieceTable(original: text)
        var utf16Lines = 0
        measure("UTF-16 newline scan through the piece table", target: 1000) {
            utf16Lines = UTF16Lines(table: table).starts.count
        }
        print("  lines: \(utf16Lines) · file is \(text.isASCII ? "ASCII" : "not ASCII (UTF-16 offsets differ from bytes)")")
        measure("find line 5,000,000's start from the sparse index", target: 1) {
            let line = min(5_000_000, sparse.count * 64 - 1)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var cursor = base + sparse[line / 64], remaining = raw.count - sparse[line / 64]
                for _ in 0..<(line % 64) {
                    guard let hit = memchr(cursor, 0x0A, remaining) else { break }
                    let next = UnsafeRawPointer(hit) + 1
                    remaining -= next - cursor
                    cursor = next
                }
            }
        }
    }

    // MARK: 2. TextKit 2 with our own content manager

    @MainActor static func textKit2Experiment() throws {
        let url = try testFile()
        let table = try measure("map file (MappedUTF8Text + PieceTable)", target: 300) { PieceTable(original: try MappedUTF8Text(url: url)) }
        let lines = measure("line index (UTF-16 scan; the real one is faster)") { UTF16Lines(table: table) }
        print("  \(lines.starts.count) lines, UTF-16 length \(table.length)")

        let font = NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let content = PieceTableContentManager(table: table, lines: lines, font: font)
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 1_000_000, height: 0))
        container.widthTracksTextView = false
        layout.textContainer = container
        content.addTextLayoutManager(layout)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Tidepad spike — TextKit 2 over the piece table"
        let scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        let view = TextKit2SpikeView(frame: scrollView.bounds, layout: layout)
        scrollView.documentView = view
        window.contentView = scrollView

        func settle() {
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        func step(_ label: String, target: Double?, _ body: () -> Void) {
            content.elementsCreated = 0
            measure(label, target: target) { body(); settle() }
            print("  elements created: \(content.elementsCreated) · document height \(Int(view.frame.height)) pt")
        }
        step("show window + lay out the first screen", target: 300) {
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            view.layoutViewport()
        }
        let middle = lines.starts[lines.starts.count / 2]
        step("jump to the middle (relocateViewport)", target: 50) { view.jump(to: middle) }
        step("jump to the end (relocateViewport)", target: 50) { view.jump(to: table.length) }
        step("jump back to the top", target: 50) { view.jump(to: 0) }
        view.jump(to: middle)
        settle()
        var worst = 0.0, total = 0.0
        content.elementsCreated = 0
        for _ in 0..<200 {
            let start = DispatchTime.now().uptimeNanoseconds
            view.scroll(NSPoint(x: 0, y: view.visibleRect.minY + 20))
            view.layoutViewport()
            window.displayIfNeeded()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            worst = max(worst, elapsed)
            total += elapsed
        }
        report("scroll 200 × 20 pt: average per step", total / 200, target: 8)
        report("scroll 200 × 20 pt: worst step", worst, target: 16)
        print("  elements created while scrolling: \(content.elementsCreated)")

        // The same screen with Core Text directly, for comparison: 60 lines from the middle.
        let context = CGContext(data: nil, width: 1100, height: 760, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let first = lines.starts.count / 2
        measure("Core Text: build + draw 60 lines (option C baseline)", target: 8) {
            for k in 0..<60 {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: lines.text(of: first + k, in: table),
                                                                               attributes: [.font: font]))
                context.textPosition = CGPoint(x: 4, y: 760 - CGFloat(k + 1) * 15)
                CTLineDraw(line, context)
            }
        }
        print("  RSS at the end: \(residentMB()) MB")
        if arguments.contains("--stay") {
            print("Window left open: scroll by hand. Quit with ⌘Q.")
            let menu = NSMenu(), item = NSMenuItem()
            item.submenu = NSMenu()
            item.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(item)
            app.mainMenu = menu
            app.run()
        }
    }

    // MARK: 2b. Core Text, measured cleanly

    /// Option C's per-screen cost in a fresh process: find 60 lines anywhere in the file through the
    /// sparse byte index, decode them, build Core Text lines and draw them. Twenty random jumps, each
    /// split into its parts, reported as median and worst.
    static func coreTextExperiment() throws {
        let url = try testFile()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let font = NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        var sparse: [Int] = [0], lineCount = 0
        measure("sparse byte index (every 64th line)", target: 250) {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var cursor = base, remaining = raw.count
                while remaining > 0, let hit = memchr(cursor, 0x0A, remaining) {
                    lineCount += 1
                    let next = UnsafeRawPointer(hit) + 1
                    if lineCount % 64 == 0 { sparse.append(next - base) }
                    remaining -= next - cursor
                    cursor = next
                }
            }
        }
        let context = CGContext(data: nil, width: 1100, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var generator = SystemRandomNumberGenerator()
        var find: [Double] = [], build: [Double] = [], draw: [Double] = []
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        for run in 0..<21 {
            let first = run == 0 ? 0 : Int.random(in: 0..<(lineCount - 60), using: &generator)
            var t = now()
            var texts: [String] = []
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var offset = sparse[first / 64]
                for _ in 0..<(first % 64) { offset = (memchr(base + offset, 0x0A, raw.count - offset).map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? raw.count - 1) + 1 }
                for _ in 0..<60 {
                    let end = memchr(base + offset, 0x0A, raw.count - offset).map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? raw.count
                    texts.append(String(decoding: UnsafeBufferPointer(start: base + offset, count: end - offset), as: UTF8.self))
                    offset = min(end + 1, raw.count)
                }
            }
            let t1 = now()
            let lines = texts.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
            let t2 = now()
            context.clear(CGRect(x: 0, y: 0, width: 1100, height: 1000))
            for (k, line) in lines.enumerated() {
                context.textPosition = CGPoint(x: 4, y: 1000 - CGFloat(k + 1) * 15)
                CTLineDraw(line, context)
            }
            let t3 = now()
            if run == 0 { t = t3; continue } // The first run warms up fonts and caches.
            find.append(Double(t1 - t) / 1e6); build.append(Double(t2 - t1) / 1e6); draw.append(Double(t3 - t2) / 1e6)
        }
        func stats(_ label: String, _ values: [Double], target: Double) {
            let sorted = values.sorted()
            report("\(label): median", sorted[sorted.count / 2], target: nil)
            report("\(label): worst", sorted.last ?? 0, target: target)
        }
        stats("find + decode 60 lines at a random line", find, target: 2)
        stats("build 60 Core Text lines", build, target: 8)
        stats("draw 60 lines", draw, target: 8)
        let totals = zip(zip(find, build), draw).map { $0.0 + $0.1 + $1 }
        stats("whole screen after a jump (all three)", totals, target: 16)
    }

    // MARK: 3. APFS clone

    /// Maps a file, has "another app" truncate it, then reads the mapping. Reading a mapped page past
    /// the new end of a file raises SIGBUS, which kills the app. The controls run in child processes:
    /// one with Foundation's mapped Data (what MappedUTF8Text uses), one with mmap directly. Then the
    /// same with an APFS clone mapped instead, which must survive.
    static func cloneExperiment() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-clone-source.txt")
        let values = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey, .volumeSupportsFileCloningKey])
        print("Volume: \(values.volumeLocalizedFormatDescription ?? "?") · supports cloning: \(values.volumeSupportsFileCloning ?? false)")

        // Is Foundation's "mapped" Data really mapped, or read into memory? Mapped pages are the file's
        // own, so the app's memory barely grows; a copy grows it by the file's size.
        let big = try testFile()
        let before = footprintMB()
        let mappedBig = try Data(contentsOf: big, options: .alwaysMapped)
        var sum = 0
        mappedBig.withUnsafeBytes { raw in var k = 0; while k < raw.count { sum &+= Int(raw[k]); k += 16_384 } }
        print("Foundation .alwaysMapped, 500 MB touched: memory +\(footprintMB() - before) MB (≈0 means really mapped) [\(sum % 7)]")

        for mode in ["foundation", "mmap"] {
            try Data(repeating: 0x41, count: 64 * 1_048_576).write(to: source)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["clone-control", mode]
            child.standardOutput = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            let crashed = child.terminationReason == .uncaughtSignal
            print("Control, \(mode) mapping of the file itself, then truncated: " +
                  (crashed ? "CRASHED with signal \(child.terminationStatus) (10 = SIGBUS) — the risk is real" : "survived"))
        }

        try Data(repeating: 0x41, count: 64 * 1_048_576).write(to: source)
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: source, create: true)
        let clone = folder.appendingPathComponent("clone.txt")
        let result = measure("clonefile (64 MB)", target: 5) { clonefile(source.path, clone.path, 0) }
        guard result == 0 else { print("clonefile failed: errno \(errno) (\(String(cString: strerror(errno))))"); return }
        let bigClone = folder.appendingPathComponent("big-clone.txt")
        measure("clonefile (the 500 MB test file)", target: 5) { _ = clonefile(big.path, bigClone.path, 0) }
        try? FileManager.default.removeItem(at: bigClone)

        let fd = open(clone.path, O_RDONLY)
        let size = 64 * 1_048_576
        guard fd >= 0, let map = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { print("mmap failed"); return }
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 0)
        try handle.close()
        let last = map.load(fromByteOffset: size - 1, as: UInt8.self)
        print("mmap of the clone, after the original was truncated: last byte \(last) (65 expected) — \(last == 0x41 ? "PASS, no crash" : "FAIL")")
        munmap(map, size)
        close(fd)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: source)
    }

    /// Child process: maps the source file itself, truncates it, reads the last byte.
    static func cloneControl() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-clone-source.txt")
        let size = 64 * 1_048_576
        if arguments.contains("mmap") {
            let fd = open(source.path, O_RDONLY)
            guard let map = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { exit(2) }
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: 0)
            try handle.close()
            print("control read: \(map.load(fromByteOffset: size - 1, as: UInt8.self))") // SIGBUS here.
        } else {
            let mapped = try Data(contentsOf: source, options: .alwaysMapped)
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: 0)
            try handle.close()
            print("control read: \(mapped[mapped.count - 1])")
        }
    }

    // MARK: 4. Very tall views

    /// A view as tall as a 50-million-line file (or --height), scrolled near the bottom and left open,
    /// to see whether text stays sharp and still or blurs and jitters.
    @MainActor static func scrollExperiment() {
        let height = CGFloat(Double(value("--height") ?? "850000000") ?? 850_000_000)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(format: "Tidepad spike — view %.0f points tall", height)
        let scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        let view = TallRowsView(frame: NSRect(x: 0, y: 0, width: 880, height: height))
        scrollView.documentView = view
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        view.scroll(NSPoint(x: 0, y: height - 2000))
        print(String(format: "Scrolled to y = %.0f. Scroll with the trackpad: rows should stay sharp, evenly spaced and still.", view.visibleRect.minY))
        print("Try again with --height 10000000 (10 million) to compare. Quit with ⌘Q.")
        let menu = NSMenu(), item = NSMenuItem()
        item.submenu = NSMenu()
        item.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(item)
        app.mainMenu = menu
        app.run()
    }
}

/// Every line start in UTF-16 offsets (the spike keeps them all; the real index will be sparse).
struct UTF16Lines {
    var starts: [Int] = [0]
    let length: Int

    init(table: PieceTable) {
        length = table.length
        let chunk = 1 << 20
        var buffer = [UInt16](repeating: 0, count: chunk)
        var offset = 0
        while offset < length {
            let count = min(chunk, length - offset)
            buffer.withUnsafeMutableBufferPointer { pointer in
                table.getCharacters(pointer.baseAddress!, range: NSRange(location: offset, length: count))
                for k in 0..<count where pointer[k] == 0x0A && offset + k + 1 < length { starts.append(offset + k + 1) }
            }
            offset += count
        }
    }

    func line(containing offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    func range(of line: Int) -> NSRange {
        let end = line + 1 < starts.count ? starts[line + 1] : length
        return NSRange(location: starts[line], length: end - starts[line])
    }

    func text(of line: Int, in table: PieceTable) -> String {
        let range = range(of: line)
        var units = [UInt16](repeating: 0, count: range.length)
        units.withUnsafeMutableBufferPointer { table.getCharacters($0.baseAddress!, range: range) }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

/// A position in the document: a UTF-16 offset.
final class OffsetLocation: NSObject, NSTextLocation {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
    func compare(_ location: any NSTextLocation) -> ComparisonResult {
        guard let other = location as? OffsetLocation else { return .orderedSame }
        return offset < other.offset ? .orderedAscending : offset > other.offset ? .orderedDescending : .orderedSame
    }
    override var description: String { "@\(offset)" }
}

/// Option B: TextKit 2 reading paragraphs straight from the piece table, one line at a time, only
/// when TextKit asks for them. The question is how many it asks for.
final class PieceTableContentManager: NSTextContentManager {
    let table: PieceTable
    let lines: UTF16Lines
    let font: NSFont
    var elementsCreated = 0

    init(table: PieceTable, lines: UTF16Lines, font: NSFont) {
        self.table = table
        self.lines = lines
        self.font = font
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not archivable") }

    override var documentRange: NSTextRange {
        NSTextRange(location: OffsetLocation(0), end: OffsetLocation(table.length))!
    }

    private func paragraph(_ line: Int) -> NSTextParagraph {
        elementsCreated += 1
        let range = lines.range(of: line)
        let paragraph = NSTextParagraph(attributedString: NSAttributedString(string: lines.text(of: line, in: table),
                                                                             attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        paragraph.textContentManager = self
        paragraph.elementRange = NSTextRange(location: OffsetLocation(range.location), end: OffsetLocation(NSMaxRange(range)))
        return paragraph
    }

    override func enumerateTextElements(from textLocation: (any NSTextLocation)?, options: NSTextContentManager.EnumerationOptions = [],
                                        using block: (NSTextElement) -> Bool) -> (any NSTextLocation)? {
        let reverse = options.contains(.reverse)
        var line: Int
        if let location = textLocation as? OffsetLocation {
            line = lines.line(containing: reverse ? max(0, location.offset - 1) : location.offset)
        } else {
            line = reverse ? lines.starts.count - 1 : 0
        }
        while line >= 0 && line < lines.starts.count {
            let element = paragraph(line)
            if !block(element) { return reverse ? element.elementRange?.location : element.elementRange?.endLocation }
            line += reverse ? -1 : 1
        }
        return nil
    }

    override func location(_ location: any NSTextLocation, offsetBy offset: Int) -> (any NSTextLocation)? {
        guard let location = location as? OffsetLocation else { return nil }
        let target = location.offset + offset
        return target >= 0 && target <= table.length ? OffsetLocation(target) : nil
    }

    override func offset(from: any NSTextLocation, to: any NSTextLocation) -> Int {
        guard let from = from as? OffsetLocation, let to = to as? OffsetLocation else { return 0 }
        return to.offset - from.offset
    }

    override func replaceContents(in range: NSTextRange, with textElements: [NSTextElement]?) {} // Read-only spike.
    override func synchronizeToBackingStore(_ completionHandler: (((any Error)?) -> Void)?) { completionHandler?(nil) }
}

/// Draws what TextKit 2's viewport controller lays out.
@MainActor final class TextKit2SpikeView: NSView, @preconcurrency NSTextViewportLayoutControllerDelegate {
    let layout: NSTextLayoutManager
    private var fragments: [NSTextLayoutFragment] = []

    init(frame: NSRect, layout: NSTextLayoutManager) {
        self.layout = layout
        super.init(frame: frame)
        layout.textViewportLayoutController.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("Not archivable") }
    override var isFlipped: Bool { true }

    func layoutViewport() { layout.textViewportLayoutController.layoutViewport() }

    func jump(to offset: Int) {
        let y = layout.textViewportLayoutController.relocateViewport(to: OffsetLocation(offset))
        scroll(NSPoint(x: 0, y: y))
        layoutViewport()
    }

    func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        let visible = enclosingScrollView?.documentVisibleRect ?? visibleRect
        return visible.insetBy(dx: 0, dy: -visible.height / 2)
    }
    func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        fragments.removeAll(keepingCapacity: true)
    }
    func textViewportLayoutController(_ textViewportLayoutController: NSTextViewportLayoutController,
                                      configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment) {
        fragments.append(textLayoutFragment)
    }
    func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        let height = max(layout.usageBoundsForTextContainer.height, enclosingScrollView?.contentSize.height ?? 0)
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: max(frame.width, 2000), height: height)) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for fragment in fragments where fragment.layoutFragmentFrame.intersects(dirtyRect) {
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
        }
    }
}

/// Numbered rows every 17 points, drawn only where visible.
final class TallRowsView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let first = Int(dirtyRect.minY / 17), last = Int(dirtyRect.maxY / 17)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                         .foregroundColor: NSColor.textColor]
        for row in first...last {
            let y = CGFloat(row) * 17
            ("row \(row.formatted()) — the quick brown fox jumps over the lazy dog" as NSString)
                .draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: y + 16, width: bounds.width, height: 1).fill()
        }
    }
}
