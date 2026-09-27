import AppKit

enum SyntaxPalette {
    static func color(for kind: SyntaxKind, dark: Bool) -> NSColor {
        switch kind {
        case .keyword: return dark ? rgb(0.80, 0.58, 0.96) : rgb(0.43, 0.16, 0.64)
        case .string: return dark ? rgb(0.85, 0.69, 0.47) : rgb(0.60, 0.25, 0.12)
        case .number: return dark ? rgb(0.63, 0.80, 0.65) : rgb(0.12, 0.44, 0.33)
        case .comment: return dark ? rgb(0.51, 0.65, 0.49) : rgb(0.28, 0.45, 0.27)
        case .literal: return dark ? rgb(0.48, 0.73, 0.95) : rgb(0.13, 0.31, 0.72)
        case .tag: return dark ? rgb(0.48, 0.78, 0.84) : rgb(0.05, 0.40, 0.49)
        case .heading: return dark ? rgb(0.54, 0.73, 1.0) : rgb(0.12, 0.32, 0.64)
        case .punctuation: return dark ? rgb(0.73, 0.75, 0.79) : rgb(0.34, 0.36, 0.40)
        }
    }
    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
