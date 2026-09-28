import Foundation

@main struct CoreChecks {
    static func main() throws {
        let index = LineIndex()
        index.rebuild("")
        precondition(index.starts == [0] && index.line(at: 0) == 0)
        index.rebuild("a\r\nb\rc\n😀\n")
        precondition(index.starts == [0, 3, 5, 7, 10])
        precondition(index.line(at: 2) == 0 && index.line(at: 3) == 1)
        precondition(index.line(at: 9) == 3 && index.line(at: 10) == 4)
        index.rebuild("single")
        precondition(index.starts == [0])
        let mutable = NSMutableString(string: "a\r\nb\rc\n😀\n")
        index.rebuild(mutable as String)
        var seed: UInt64 = 17
        let insertions = ["", "a", "\r", "\n", "\r\n", "😀", "x\u{2028}y"]
        for _ in 0..<2000 {
            seed = seed &* 6364136223846793005 &+ 1
            let location = Int(seed % UInt64(mutable.length + 1))
            let count = min(Int((seed >> 8) % 4), mutable.length - location)
            let replacement = insertions[Int((seed >> 16) % UInt64(insertions.count))]
            // NSString permits arbitrary UTF-16 ranges; avoid splitting surrogate pairs in this fixture.
            let range = mutable.rangeOfComposedCharacterSequences(for: NSRange(location: location, length: count))
            mutable.replaceCharacters(in: range, with: replacement)
            let added = (replacement as NSString).length
            index.applyEdit(in: mutable, range: NSRange(location: range.location, length: added), delta: added - range.length)
            let expected = LineIndex(); expected.rebuild(mutable as String)
            precondition(index.starts == expected.starts && index.lineEnding == expected.lineEnding, "Incremental line boundaries")
            precondition(index.characters(in: NSRange(location: 0, length: mutable.length), text: mutable) == (mutable as String).count, "Indexed Unicode selection length")
        }
        let service = TextFileService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for encoding in [String.Encoding.utf8, .utf16] {
            let url = directory.appendingPathComponent("sample.txt")
            let content = "Hello 😀\r\nSecond line\r\n"
            let document = EditorDocument(text: content, encoding: encoding)
            precondition(!document.hasUnsavedChanges && document.lineEnding == .crlf)
            document.text += "changed"
            precondition(document.hasUnsavedChanges)
            document.text = content
            precondition(!document.hasUnsavedChanges)
            try service.write(document, to: url)
            let loaded = try service.read(url)
            precondition(loaded.text == content && loaded.lineEnding == .crlf)
            loaded.text = "replacement\n"
            precondition(loaded.preparedLines == nil, "Explicit replacement invalidates the prepared loading index")
            document.markSaved(at: url)
            precondition(document.displayName == "sample.txt" && !document.hasUnsavedChanges)
        }
        for (encoding, prefix) in [(String.Encoding.utf8, [UInt8(0xEF), 0xBB, 0xBF]), (.utf16LittleEndian, [0xFF, 0xFE]), (.utf16BigEndian, [0xFE, 0xFF]), (.utf32LittleEndian, [0xFF, 0xFE, 0x00, 0x00]), (.utf32BigEndian, [0x00, 0x00, 0xFE, 0xFF])] {
            let url = directory.appendingPathComponent("bom.txt")
            let document = EditorDocument(text: "BOM test 😀", encoding: encoding)
            document.hasByteOrderMark = true
            try service.write(document, to: url)
            let bytes = try Data(contentsOf: url)
            precondition(bytes.starts(with: prefix))
            let loaded = try service.read(url)
            precondition(loaded.hasByteOrderMark && loaded.encoding == encoding && loaded.text == document.text)
            try service.write(loaded, to: url)
            let roundTrip = try Data(contentsOf: url)
            precondition(roundTrip == bytes, "Save must preserve BOM without duplicating it")
        }
        // Saving keeps the file's permissions and writes through symlinks instead of replacing them.
        let script = directory.appendingPathComponent("tool.sh")
        try "echo one\n".write(to: script, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let link = directory.appendingPathComponent("tool-link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
        let linked = try service.read(link)
        linked.text = "echo two\n"
        try service.write(linked, to: link)
        let linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        precondition(linkDestination == script.path, "Save must not replace a symlink with a regular file")
        let scriptText = try String(contentsOf: script, encoding: .utf8)
        precondition(scriptText == "echo two\n", "Save must write through the symlink")
        let mode = (try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(mode == 0o755, "Save must keep the file's permissions")
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let url = directory.appendingPathComponent("no-bom.txt")
            try "Plain text without BOM\n".data(using: encoding)?.write(to: url)
            var expectedEncoding = String.Encoding.utf8
            if let expected = try? String(contentsOf: url, usedEncoding: &expectedEncoding) {
                let loaded = try service.read(url)
                precondition(loaded.text == expected && loaded.encoding == expectedEncoding, "Preserve native BOM-less encoding detection")
            }
        }
        // BOM-less Windows-1252 text that isn't valid UTF-8 must open, and save back byte for byte.
        let western = directory.appendingPathComponent("western.txt")
        let westernBytes = Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x93, 0x71, 0x94, 0x0D, 0x0A]) // café “q”\r\n
        try westernBytes.write(to: western)
        var detected = String.Encoding.utf8
        if (try? String(contentsOf: western, usedEncoding: &detected)) == nil {
            let loaded = try service.read(western)
            precondition(loaded.encoding == .windowsCP1252 && loaded.text == "caf\u{E9} \u{201C}q\u{201D}\r\n", "Windows-1252 fallback")
            try service.write(loaded, to: western)
            let roundTrip = try Data(contentsOf: western)
            precondition(roundTrip == westernBytes, "Windows-1252 must round-trip")
        }
        let overridden = EditorDocument(fileURL: URL(fileURLWithPath: "/sample.swift"))
        precondition(overridden.syntaxLanguage == .swift)
        overridden.languageOverride = .json
        overridden.markSaved(at: URL(fileURLWithPath: "/sample.java"))
        precondition(overridden.syntaxLanguage == .json && !overridden.hasUnsavedChanges)
        overridden.languageOverride = nil
        precondition(overridden.syntaxLanguage == .java)
        // File stamps tell real content changes (by other apps) from metadata-only notifications.
        let stamped = directory.appendingPathComponent("stamp.txt")
        try "a".write(to: stamped, atomically: false, encoding: .utf8)
        let firstStamp = FileStamp(stamped)
        precondition(firstStamp != nil)
        let stampedDocument = try service.read(stamped)
        precondition(stampedDocument.diskStamp == firstStamp, "Loading records the file's stamp")
        try "abc".write(to: stamped, atomically: false, encoding: .utf8)
        precondition(FileStamp(stamped) != firstStamp, "The stamp changes with the content")
        try FileManager.default.removeItem(at: stamped)
        precondition(FileStamp(stamped) == nil, "No stamp for a missing file")
        let kept = EditorDocument(text: "x")
        kept.markUnsaved()
        precondition(kept.hasUnsavedChanges, "A deleted-but-kept document needs saving")
        // Encoding menu: line ending conversion, reopening in a chosen encoding, converting.
        precondition(LineEnding.crlf.applied(to: "a\nb\r\nc\rd") == "a\r\nb\r\nc\r\nd", "Convert to CRLF")
        precondition(LineEnding.lf.applied(to: "a\r\nb\rc\n") == "a\nb\nc\n" && LineEnding.cr.applied(to: "a\r\nb\n") == "a\rb\r")
        let bomUTF16 = TextEncodingChoice.utf16LittleEndian.decode(Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]))
        precondition(bomUTF16?.text == "hi" && bomUTF16?.hadByteOrderMark == true, "UTF-16 LE skips its BOM")
        precondition(TextEncodingChoice.utf16BigEndian.decode(Data([0x00, 0x68, 0x00, 0x69]))?.text == "hi")
        precondition(TextEncodingChoice.utf8.decode(Data([0xE9])) == nil, "Invalid UTF-8 isn't opened as UTF-8")
        precondition(TextEncodingChoice.windowsWestern.firstUnwritableCharacter(in: "café “q”") == nil)
        precondition(TextEncodingChoice.windowsWestern.firstUnwritableCharacter(in: "ab中c") == "中", "Unwritable characters are found")
        precondition(TextEncodingChoice.matching(.utf8, byteOrderMark: true) == .utf8WithBOM
                     && TextEncodingChoice.matching(.windowsCP1252, byteOrderMark: false) == .windowsWestern)
        precondition(TextEncodingChoice.others.allSatisfy { String.availableStringEncodings.contains($0.encoding) }, "Every offered encoding exists")
        let reopened = directory.appendingPathComponent("reopen.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: reopened)
        let asWestern = try service.load(reopened, as: .windowsWestern)
        precondition(asWestern.text == "caf\u{E9}" && asWestern.encoding == .windowsCP1252, "Reopen as Windows 1252")
        precondition((try? service.load(reopened, as: .utf8)) == nil, "Reopening in an encoding the bytes don't fit fails")
        let converted = EditorDocument(text: "h\u{E9}llo\r\n")
        for choice in TextEncodingChoice.common + TextEncodingChoice.others {
            converted.encoding = choice.encoding
            converted.hasByteOrderMark = choice.byteOrderMark
            let file = directory.appendingPathComponent("converted.txt")
            try? FileManager.default.removeItem(at: file)
            if choice.firstUnwritableCharacter(in: converted.text) != nil {
                precondition((try? service.write(converted, to: file)) == nil, "Saving never drops characters (\(choice.name))")
                continue
            }
            try service.write(converted, to: file)
            let back = try service.load(file, as: choice)
            precondition(back.text == converted.text && back.hasBOM == choice.byteOrderMark, "Round trip in \(choice.name)")
        }
        print("Core checks passed: line offsets, Unicode, CRLF/CR/LF, dirty state, UTF-8/UTF-16 file round trips, encodings and line ending conversion.")
    }
}
