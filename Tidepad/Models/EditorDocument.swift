import Foundation
import Observation

enum LineEnding: String, CaseIterable {
    case lf = "LF", crlf = "CRLF", cr = "CR"

    var statusName: String {
        switch self {
        case .lf: return "Unix (LF)"
        case .crlf: return "Windows (CRLF)"
        case .cr: return "Macintosh (CR)"
        }
    }

    /// The characters written for this line ending.
    var text: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    static func detect(in text: String) -> LineEnding {
        if text.contains("\r\n") { return .crlf }
        return text.contains("\r") ? .cr : .lf
    }
}

/// A text's length and a hash of all of it (UTF-16): enough to tell, after Undo or Redo, whether the
/// editor is back at the text last saved, without keeping a copy of that text (Rule 2).
struct TextFingerprint: Equatable, Sendable {
    let length: Int
    let hash: Int
    private static let chunk = 8_192

    init(_ text: NSString) {
        var hasher = Hasher()
        var buffer = [unichar](repeating: 0, count: Self.chunk)
        var location = 0
        while location < text.length {
            let count = min(Self.chunk, text.length - location)
            buffer.withUnsafeMutableBufferPointer { units in
                text.getCharacters(units.baseAddress!, range: NSRange(location: location, length: count))
                hasher.combine(bytes: UnsafeRawBufferPointer(start: units.baseAddress, count: count * 2))
            }
            location += count
        }
        length = text.length
        hash = hasher.finalize()
    }

    /// The same, from a String (files are fingerprinted as they load, off the main thread).
    init(_ text: String) {
        var hasher = Hasher()
        var buffer: [UInt16] = []
        buffer.reserveCapacity(Self.chunk)
        var length = 0
        func flush() {
            buffer.withUnsafeBytes { hasher.combine(bytes: $0) }
            length += buffer.count
            buffer.removeAll(keepingCapacity: true)
        }
        for unit in text.utf16 {
            buffer.append(unit)
            if buffer.count == Self.chunk { flush() }
        }
        flush()
        self.length = length
        hash = hasher.finalize()
    }
}

@Observable final class EditorDocument: Identifiable {
    @ObservationIgnored var preparedLines: LineIndex.Prepared?
    /// The fingerprint of the text last loaded or saved, for the normal editor (nil once that text
    /// can't be returned to by Undo, e.g. after markUnsaved).
    @ObservationIgnored var savedFingerprint: TextFingerprint?
    @ObservationIgnored var saveBoundary: (() -> Void)?
    /// The file version this document was last loaded from or saved to.
    @ObservationIgnored var diskStamp: FileStamp?
    let id = UUID()
    var fileURL: URL?
    var displayName: String
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var storedText: String
    @ObservationIgnored private var snapshot: String?
    @ObservationIgnored private var readLiveText: (() -> String)?
    @ObservationIgnored private var replaceLiveText: ((String) -> Void)?
    @ObservationIgnored private var savedText: String?
    @ObservationIgnored private var state: UInt64 = 0
    @ObservationIgnored private var savedState: UInt64 = 0
    private(set) var hasUnsavedChanges = false

    /// Search and Save request an immutable snapshot lazily; typing never calls this getter.
    var text: String {
        get {
            if readLiveText == nil { return storedText }
            if let snapshot { return snapshot }
            let value = readLiveText?() ?? storedText
            snapshot = value
            return value
        }
        set {
            if let replaceLiveText { replaceLiveText(newValue); return }
            storedText = newValue
            preparedLines = nil
            revision &+= 1
            hasUnsavedChanges = newValue != savedText
        }
    }

    func attachStorage(read: @escaping () -> String, replace: @escaping (String) -> Void) {
        if hasUnsavedChanges { state = max(1, revision) }
        readLiveText = read; replaceLiveText = replace
        storedText = ""; savedText = nil; snapshot = nil
    }

    func recordEdit() {
        revision &+= 1; snapshot = nil
    }

    var editingState: UInt64 { state }
    /// The editing state of the text last saved (`UInt64.max` when Undo can't return to it).
    var savedEditingState: UInt64 { savedState }
    func setEditingState(_ value: UInt64) {
        state = value
        hasUnsavedChanges = state != savedState
    }
    var encoding: String.Encoding
    var hasByteOrderMark = false
    /// A file too large for NSTextView (see LargeTextFile), edited in the large-file view instead
    /// (LargeTextView) as a piece table over the mapped file. Its text is never held as a String:
    /// `text` stays empty.
    var largeBuffer: LargeTextBuffer?
    var isLarge: Bool { largeBuffer != nil }
    var languageOverride: SyntaxLanguage?
    var lineEnding: LineEnding
    var utf16Length = 0
    var lineCount = 1
    var selectionLength = 0
    var cursorLine = 1
    var cursorColumn = 1

    init(fileURL: URL? = nil, displayName: String = "Untitled", text: String = "",
         encoding: String.Encoding = .utf8, lineEnding: LineEnding? = nil) {
        self.fileURL = fileURL
        self.displayName = displayName
        self.storedText = text
        self.savedText = text
        self.encoding = encoding
        self.lineEnding = lineEnding ?? LineEnding.detect(in: text)
    }

    func markSaved(at url: URL) {
        saveBoundary?()
        fileURL = url
        displayName = url.lastPathComponent
        savedState = state
        if readLiveText == nil { savedText = storedText }
        hasUnsavedChanges = false
    }

    /// Marks the document as having changes to save without editing it, e.g. when its file was
    /// deleted by another app and the user keeps it open. Undo can't return to this "saved" state.
    func markUnsaved() {
        savedState = UInt64.max
        savedFingerprint = nil
        savedText = nil
        hasUnsavedChanges = true
    }

    var encodingName: String {
        switch encoding {
        case .utf8: return hasByteOrderMark ? "UTF-8 BOM" : "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        default: return TextEncodingChoice.matching(encoding, byteOrderMark: hasByteOrderMark)?.name ?? String.localizedName(of: encoding)
        }
    }

    /// The Encoding menu's choice for this document's encoding, if it offers one.
    var encodingChoice: TextEncodingChoice? { TextEncodingChoice.matching(encoding, byteOrderMark: hasByteOrderMark) }
}

extension EditorDocument {
    var syntaxLanguage: SyntaxLanguage { languageOverride ?? SyntaxLanguage(fileExtension: fileURL?.pathExtension) }

    var languageName: String {
        if languageOverride == .plain { return "Normal text" }
        if syntaxLanguage != .plain { return syntaxLanguage.displayName }
        guard let ext = fileURL?.pathExtension.lowercased(), !ext.isEmpty, ext != "txt" else { return "Normal text" }
        return ext == "log" ? "Log file" : "\(ext.uppercased()) file"
    }
}
