import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// A text encoding as the Encoding menu offers it: a Foundation encoding, whether saved files start
/// with a byte order mark, and its name in menus and the status bar.
struct TextEncodingChoice: Hashable, Identifiable, Sendable {
    let name: String
    let encoding: String.Encoding
    let byteOrderMark: Bool
    var id: String { name }

    init(_ name: String, _ encoding: String.Encoding, byteOrderMark: Bool = false) {
        self.name = name
        self.encoding = encoding
        self.byteOrderMark = byteOrderMark
    }

    static let utf8 = TextEncodingChoice("UTF-8", .utf8)
    static let utf8WithBOM = TextEncodingChoice("UTF-8 with BOM", .utf8, byteOrderMark: true)
    static let utf16LittleEndian = TextEncodingChoice("UTF-16 LE", .utf16LittleEndian, byteOrderMark: true)
    static let utf16BigEndian = TextEncodingChoice("UTF-16 BE", .utf16BigEndian, byteOrderMark: true)
    static let windowsWestern = TextEncodingChoice("Western (Windows 1252)", .windowsCP1252)

    /// The encodings at the top of the menu, as in Notepad++.
    static let common: [TextEncodingChoice] = [utf8, utf8WithBOM, utf16LittleEndian, utf16BigEndian, windowsWestern]

    /// Older single- and multi-byte encodings, for files from other systems.
    static let others: [TextEncodingChoice] = {
        var list = [
            TextEncodingChoice("Western (ISO Latin 1)", .isoLatin1),
            TextEncodingChoice("Western (Mac OS Roman)", .macOSRoman),
            TextEncodingChoice("Central European (Windows 1250)", .windowsCP1250),
            TextEncodingChoice("Cyrillic (Windows 1251)", .windowsCP1251),
            TextEncodingChoice("Greek (Windows 1253)", .windowsCP1253),
            TextEncodingChoice("Turkish (Windows 1254)", .windowsCP1254),
            TextEncodingChoice("Japanese (Shift JIS)", .shiftJIS),
            TextEncodingChoice("Japanese (EUC)", .japaneseEUC)
        ]
        #if canImport(CoreFoundation)
        func coreFoundation(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        list += [
            TextEncodingChoice("Chinese (GB 18030)", coreFoundation(.GB_18030_2000)),
            TextEncodingChoice("Chinese (Big 5)", coreFoundation(.big5)),
            TextEncodingChoice("Korean (EUC-KR)", coreFoundation(.EUC_KR)),
            TextEncodingChoice("Hebrew (Windows 1255)", coreFoundation(.windowsHebrew)),
            TextEncodingChoice("Arabic (Windows 1256)", coreFoundation(.windowsArabic))
        ]
        #endif
        return list
    }()

    /// Every encoding a file can be reopened as. "UTF-8 with BOM" is left out: reopening as UTF-8
    /// already skips a BOM and keeps it.
    static var reopenable: [TextEncodingChoice] { (common + others).filter { $0 != utf8WithBOM } }

    /// The choice that describes a document's encoding, if it's one the menu offers.
    static func matching(_ encoding: String.Encoding, byteOrderMark: Bool) -> TextEncodingChoice? {
        let all = common + others
        if encoding == .utf8 { return byteOrderMark ? utf8WithBOM : utf8 }
        if encoding == .utf16 { return utf16LittleEndian } // Foundation's generic UTF-16 is written little-endian with a BOM.
        return all.first { $0.encoding == encoding }
    }

    /// The byte order mark files in this encoding start with, if it has one.
    var byteOrderMarkBytes: [UInt8] {
        switch encoding {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: return [0xFF, 0xFE]
        case .utf16BigEndian: return [0xFE, 0xFF]
        default: return []
        }
    }

    /// A file's bytes read in this encoding (Encoding ▸ Reopen with Encoding), skipping a byte order
    /// mark for it. Nil when the bytes aren't valid in this encoding.
    func decode(_ data: Data) -> (text: String, hadByteOrderMark: Bool)? {
        let mark = byteOrderMarkBytes
        let hasMark = !mark.isEmpty && data.starts(with: mark)
        guard let text = String(data: hasMark ? data.dropFirst(mark.count) : data, encoding: encoding) else { return nil }
        return (text, hasMark)
    }

    /// The first character of `text` that can't be written in this encoding, or nil if all of it can
    /// (Encoding ▸ Convert to won't lose characters silently).
    func firstUnwritableCharacter(in text: String) -> Character? {
        if text.data(using: encoding, allowLossyConversion: false) != nil { return nil }
        return text.first { String($0).data(using: encoding, allowLossyConversion: false) == nil }
    }
}

extension LineEnding {
    /// `text` with every line break (CRLF, CR or LF) changed to this one.
    func applied(to text: String) -> String {
        let unix = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return self == .lf ? unix : unix.replacingOccurrences(of: "\n", with: self.text)
    }
}
