import AppKit

/// Dynamic colors shared by AppKit text rendering and SwiftUI workspace controls.
enum TidepadTheme {
    static let editorBackground = color(light: 0xFFFFFF, dark: 0x202020)
    static let editorText = color(light: 0x202020, dark: 0xD4D4D4)
    static let caret = color(light: 0x171717, dark: 0xEEEEEE)
    static let currentLine = color(light: 0xF3F5F7, dark: 0x282828)
    static let gutterBackground = color(light: 0xF0F0F0, dark: 0x191919)
    static let gutterText = color(light: 0x777777, dark: 0x858585)
    static let toolbarBackground = color(light: 0xEDEDED, dark: 0x303030)
    static let tabStripBackground = color(light: 0xDCDCDC, dark: 0x151515)
    static let inactiveTabBackground = color(light: 0xE4E4E4, dark: 0x1B1B1B)
    static let activeTabBackground = editorBackground
    static let activeTabText = color(light: 0x181818, dark: 0xEEEEEE)
    static let inactiveTabText = color(light: 0x555555, dark: 0xA0A0A0)
    static let tabAccent = color(light: 0xDC8A28, dark: 0xDA9D47)
    static let statusBackground = color(light: 0xE8E8E8, dark: 0x2C2C2C)
    static let chromeText = color(light: 0x363636, dark: 0xC5C5C5)
    static let separator = color(light: 0xBCBCBC, dark: 0x434343)
    static let buttonPressed = color(light: 0xC9DCEC, dark: 0x45515C)
    static let buttonHover = color(light: 0xDCE4EA, dark: 0x3C4248)
    static let fileIcon = color(light: 0x418354, dark: 0x85B88E)
    static let modified = color(light: 0xAA610D, dark: 0xE9AC51)
    static let toolbarNew = color(light: 0x45804B, dark: 0x9ABD91)
    static let toolbarOpen = color(light: 0xA07C27, dark: 0xD2B568)
    static let toolbarSave = color(light: 0x386B9E, dark: 0x8FB8DE)
    static let toolbarUndo = color(light: 0x547BA3, dark: 0x99B4D0)
    static let toolbarClipboard = color(light: 0x596D7E, dark: 0xB0BCC6)
    static let toolbarFind = color(light: 0x765F91, dark: 0xBAA5D2)
    static let toolbarClose = color(light: 0x9E4F4A, dark: 0xD9A19C)
    static let bracketFill = color(light: 0xDDE8F4, dark: 0x354453)
    static let bracketBorder = color(light: 0x8AA9C8, dark: 0x6B8BAA)
    static let sidebarBackground = color(light: 0xF3F3F3, dark: 0x1B1B1B)

    private static func color(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}
