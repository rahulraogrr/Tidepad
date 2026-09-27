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

    static func detect(in text: String) -> LineEnding {
        if text.contains("\r\n") { return .crlf }
        return text.contains("\r") ? .cr : .lf
    }
}

@Observable final class EditorDocument: Identifiable {
    @ObservationIgnored var preparedLines: LineIndex.Prepared?
    @ObservationIgnored var saveBoundary: (() -> Void)?
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
    func setEditingState(_ value: UInt64) {
        state = value
        hasUnsavedChanges = state != savedState
    }
    var encoding: String.Encoding
    var hasByteOrderMark = false
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

    var encodingName: String {
        switch encoding {
        case .utf8: return hasByteOrderMark ? "UTF-8 BOM" : "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        default: return String.localizedName(of: encoding)
        }
    }
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
