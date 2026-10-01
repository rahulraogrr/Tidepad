import AppKit
import Observation

enum EditorAppearance: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct EditorDisplayOptions: Equatable {
    var font = EditorFontConfiguration.standard
    var showLineNumbers = true
    var wordWrap = false
}

/// The user's settings. Each one is saved in the user defaults as soon as it changes, and read back
/// at launch.
@Observable final class EditorPreferences {
    var showLineNumbers = true { didSet { save(showLineNumbers, "showLineNumbers") } }
    var showStatusBar = true { didSet { save(showStatusBar, "showStatusBar") } }
    var showToolbar = true { didSet { save(showToolbar, "showToolbar") } }
    var wordWrap = false { didSet { save(wordWrap, "wordWrap") } }
    var appearance = EditorAppearance.system { didSet { save(appearance.rawValue, "appearance") } }
    var fontName: String? { didSet { save(fontName, "fontName") } }
    var fontSize = TidepadMetrics.editorFontSize { didSet { save(Double(fontSize), "fontSize") } }
    var tabSize = 4 { didSet { save(tabSize, "tabSize") } }
    /// TidePad ▸ Check for Updates… also runs by itself, at most once a week (UpdateController).
    var checkForUpdates = true { didSet { save(checkForUpdates, "checkForUpdates") } }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String) -> T? { defaults.object(forKey: Self.prefix + key) as? T }
        showLineNumbers = value("showLineNumbers") ?? true
        showStatusBar = value("showStatusBar") ?? true
        showToolbar = value("showToolbar") ?? true
        wordWrap = value("wordWrap") ?? false
        appearance = (value("appearance") as String?).flatMap(EditorAppearance.init(rawValue:)) ?? .system
        fontName = value("fontName")
        fontSize = (value("fontSize") as Double?).map { CGFloat(min(48, max(8, $0))) } ?? TidepadMetrics.editorFontSize
        tabSize = (value("tabSize") as Int?).map { min(16, max(1, $0)) } ?? 4
        checkForUpdates = value("checkForUpdates") ?? true
    }

    private static let prefix = "Tidepad.Preferences."

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: Self.prefix + key) } else { defaults.removeObject(forKey: Self.prefix + key) }
    }

    var displayOptions: EditorDisplayOptions {
        var font = EditorFontConfiguration.standard
        font.preferredFamily = fontName ?? font.preferredFamily
        font.size = fontSize
        font.tabWidth = tabSize
        return EditorDisplayOptions(font: font, showLineNumbers: showLineNumbers, wordWrap: wordWrap)
    }
}
