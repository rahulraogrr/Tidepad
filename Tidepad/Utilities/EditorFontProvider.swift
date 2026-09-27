import AppKit

struct EditorFontConfiguration: Equatable {
    var preferredFamily = "Consolas"
    var fallbackFamily = "Menlo"
    var size: CGFloat = TidepadMetrics.editorFontSize
    var tabWidth = 4
    static let standard = EditorFontConfiguration()
}

enum EditorFontProvider {
    static func font(configuration: EditorFontConfiguration = .standard) -> NSFont {
        NSFont(name: configuration.preferredFamily, size: configuration.size)
            ?? NSFont(name: configuration.fallbackFamily, size: configuration.size)
            ?? NSFont.monospacedSystemFont(ofSize: configuration.size, weight: .regular)
    }

    static func paragraphStyle(font: NSFont, configuration: EditorFontConfiguration = .standard) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(configuration.tabWidth)
        return style
    }
}
