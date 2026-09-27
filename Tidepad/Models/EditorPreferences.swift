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

@Observable final class EditorPreferences {
    var showLineNumbers = true
    var showStatusBar = true
    var showToolbar = true
    var wordWrap = false
    var appearance = EditorAppearance.system
    var fontName: String?
    var fontSize = TidepadMetrics.editorFontSize
    var tabSize = 4

    var displayOptions: EditorDisplayOptions {
        var font = EditorFontConfiguration.standard
        font.preferredFamily = fontName ?? font.preferredFamily
        font.size = fontSize
        font.tabWidth = tabSize
        return EditorDisplayOptions(font: font, showLineNumbers: showLineNumbers, wordWrap: wordWrap)
    }
}
