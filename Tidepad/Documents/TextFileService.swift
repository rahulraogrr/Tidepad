import Foundation

/// Decode off the main actor; AppKit receives the resulting immutable value on the main actor.
struct LoadedText: Sendable {
    let url: URL
    let text: String
    let encoding: String.Encoding
    let hasBOM: Bool
    let lines: LineIndex.Prepared
    func makeDocument() -> EditorDocument {
        let document = EditorDocument(fileURL: url, displayName: url.lastPathComponent,
            text: text, encoding: encoding, lineEnding: lines.lineEnding)
        document.hasByteOrderMark = hasBOM
        document.preparedLines = lines
        return document
    }
}

struct TextFileService {
    func read(_ url: URL) throws -> EditorDocument { try load(url).makeDocument() }

    func load(_ url: URL) throws -> LoadedText {
        let data = try Data(contentsOf: url)
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
            // Retain Foundation's existing encoding detection for non-UTF-8 legacy text.
            text = try String(contentsOf: url, usedEncoding: &encoding)
        }
        return LoadedText(url: url, text: text, encoding: encoding, hasBOM: signature != nil,
                          lines: LineIndex.Prepared(text))
    }

    func write(_ document: EditorDocument, to url: URL) throws {
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
        try data.write(to: url, options: .atomic)
    }
}
