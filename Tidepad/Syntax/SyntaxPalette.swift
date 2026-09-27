import AppKit

/// Notepad++'s default ("classic") style in light mode, with brighter equivalents for dark mode.
/// Keywords and operators are drawn bold (see CodeLayoutManager), as in Notepad++.
enum SyntaxPalette {
    static func color(for kind: SyntaxKind, language: SyntaxLanguage = .plain, dark: Bool) -> NSColor {
        switch kind {
        case .keyword, .literal: return dark ? hex(0x6CA8FF) : hex(0x0000FF) // instruction words: blue
        case .string:
            // Markup strings are attribute values (purple); other strings are grey.
            if language.isMarkup { return dark ? hex(0xC792FF) : hex(0x8000FF) }
            return dark ? hex(0xB4B4B4) : hex(0x808080)
        case .number: return dark ? hex(0xFFA040) : hex(0xFF8000)            // orange
        case .comment: return dark ? hex(0x5FB85F) : hex(0x008000)           // green
        case .punctuation: return dark ? hex(0xA8B8FF) : hex(0x000080)       // operators: navy
        case .tag: return dark ? hex(0x6CA8FF) : hex(0x0000FF)               // tag names: blue
        case .attribute: return dark ? hex(0xFF7373) : hex(0xFF0000)         // attribute names: red
        case .heading: return dark ? hex(0x6CA8FF) : hex(0x000080)
        }
    }

    /// Kinds Notepad++ shows in bold.
    static func isBold(_ kind: SyntaxKind) -> Bool {
        switch kind {
        case .keyword, .literal, .punctuation, .heading: return true
        default: return false
        }
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
