import Foundation

/// Identifies one version of a file on disk (modification date and size), so real changes by other
/// apps can be told apart from metadata-only notifications and from Tidepad's own saves.
struct FileStamp: Equatable, Sendable {
    let modified: Date?
    let size: Int?

    /// nil when the file doesn't exist (or can't be inspected).
    init?(_ url: URL) {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              values.contentModificationDate != nil || values.fileSize != nil else { return nil }
        modified = values.contentModificationDate
        size = values.fileSize
    }
}

/// Decode off the main actor; AppKit receives the resulting immutable value on the main actor.
extension FileStamp {
    /// A stamp recorded earlier (the session keeps them across launches).
    init(modified: Date?, size: Int?) {
        self.modified = modified
        self.size = size
    }
}

struct LoadedText: Sendable {
    let url: URL
    let text: String
    let encoding: String.Encoding
    let hasBOM: Bool
    let lines: LineIndex.Prepared
    let stamp: FileStamp?
    func makeDocument() -> EditorDocument {
        let document = EditorDocument(fileURL: url, displayName: url.lastPathComponent,
            text: text, encoding: encoding, lineEnding: lines.lineEnding)
        document.hasByteOrderMark = hasBOM
        document.preparedLines = lines
        document.diskStamp = stamp
        return document
    }
}

/// A file opened for a tab: as text, or in the large-file view when it's at least LargeTextFile.threshold.
enum OpenedFile: Sendable {
    case text(LoadedText)
    case large(LargeTextFile)

    func makeDocument() -> EditorDocument {
        switch self {
        case .text(let loaded): return loaded.makeDocument()
        case .large(let file):
            let ending: LineEnding
            switch file.lineBreak {
            case .lf: ending = .lf
            case .crlf: ending = .crlf
            case .cr: ending = .cr
            }
            let document = EditorDocument(fileURL: file.url, displayName: file.url.lastPathComponent, text: "",
                                          encoding: .utf8, lineEnding: ending)
            document.hasByteOrderMark = file.hasByteOrderMark
            document.largeBuffer = LargeTextBuffer(file: file)
            document.diskStamp = FileStamp(file.url)
            document.lineCount = file.lineCount
            document.utf16Length = file.count - file.contentStart
            return document
        }
    }
}

struct TextFileService {
    func read(_ url: URL) throws -> EditorDocument { try open(url).makeDocument() }

    /// Opens a file for a tab, in the large-file view if it's large.
    func open(_ url: URL) throws -> OpenedFile {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size >= LargeTextFile.threshold { return .large(try LargeTextFile(url: url)) }
        return .text(try load(url))
    }

    /// Reads a file. Its encoding is detected, unless `choice` names one (Encoding ▸ Reopen with Encoding).
    func load(_ url: URL, as choice: TextEncodingChoice? = nil) throws -> LoadedText {
        let stamp = FileStamp(url) // Before reading: a change during the read then still looks external.
        let data = try Data(contentsOf: url)
        if let choice {
            guard let decoded = choice.decode(data) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            return LoadedText(url: url, text: decoded.text, encoding: choice.encoding, hasBOM: decoded.hadByteOrderMark,
                              lines: LineIndex.Prepared(decoded.text), stamp: stamp)
        }
        let signatures: [(bytes: [UInt8], encoding: String.Encoding)] = [
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian)
        ]
        let signature = signatures.first { data.starts(with: $0.bytes) }
        var encoding = signature?.encoding ?? .utf8
        // BOM-less UTF-16 ASCII is also valid UTF-8 bytes with NULs. Preserve Foundation's
        // detection for that ambiguous case instead of silently opening interleaved NUL text.
        let ambiguous = signature == nil && data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            return memchr(base, 0, bytes.count) != nil
        }
        let decoded = ambiguous ? nil : String(data: data.dropFirst(signature?.bytes.count ?? 0), encoding: encoding)
        let text: String
        if let decoded { text = decoded }
        else {
            do {
                // Retain Foundation's existing encoding detection for non-UTF-8 legacy text.
                text = try String(contentsOf: url, usedEncoding: &encoding)
            } catch where signature == nil && !ambiguous {
                // BOM-less 8-bit text that isn't UTF-8 (typically Windows files). Foundation usually can't
                // detect it, so fall back like Notepad++ does: Windows-1252, then Latin-1, which accepts any byte.
                if let western = String(data: data, encoding: .windowsCP1252) { encoding = .windowsCP1252; text = western }
                else if let latin = String(data: data, encoding: .isoLatin1) { encoding = .isoLatin1; text = latin }
                else { throw error }
            }
        }
        return LoadedText(url: url, text: text, encoding: encoding, hasBOM: signature != nil,
                          lines: LineIndex.Prepared(text), stamp: stamp)
    }

    func write(_ document: EditorDocument, to url: URL) throws {
        // A large file is streamed from its pieces, never held as one String (see LargeTextBuffer.write).
        if let buffer = document.largeBuffer { try buffer.write(to: url); return }
        guard var data = document.text.data(using: document.encoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if document.hasByteOrderMark {
            let prefix: [UInt8]
            switch document.encoding {
            case .utf8: prefix = [0xEF, 0xBB, 0xBF]
            case .utf16LittleEndian: prefix = [0xFF, 0xFE]
            case .utf16BigEndian: prefix = [0xFE, 0xFF]
            case .utf32LittleEndian: prefix = [0xFF, 0xFE, 0x00, 0x00]
            case .utf32BigEndian: prefix = [0x00, 0x00, 0xFE, 0xFF]
            default: prefix = [] // Foundation includes the BOM when encoding as generic UTF-16.
            }
            data.insert(contentsOf: prefix, at: 0)
        }
        // Write through symlinks to the real file. Replacing via a temporary file on the same volume
        // keeps the save atomic while preserving the original's permissions (e.g. +x), ACLs and xattrs.
        let target = url.resolvingSymlinksInPath()
        let files = FileManager.default
        guard files.fileExists(atPath: target.path) else {
            try data.write(to: target, options: .atomic)
            return
        }
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: target, create: true)
        defer { try? files.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent(target.lastPathComponent)
        try data.write(to: temporary)
        _ = try files.replaceItemAt(target, withItemAt: temporary)
    }
}
