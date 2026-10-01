import SwiftUI

struct StatusBarView: View {
    let document: EditorDocument?

    var body: some View {
        let _ = EditorDiagnostics.view("StatusBarView")
        HStack(spacing: 0) {
            Text(document.map(Self.kind) ?? "No document")
                .lineLimit(1).padding(.horizontal, TidepadMetrics.statusHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            section("length: \(document?.utf16Length ?? 0)  lines: \(document?.lineCount ?? 0)")
                .help("Length in UTF-16 code units; logical line count")
            section("Ln: \(document?.cursorLine ?? 1)  Col: \(document?.cursorColumn ?? 1)")
                .help("Column counts Unicode characters; tabs count as one character")
            section("Sel: \(document?.selectionLength ?? 0)")
                .help("Selected Unicode characters")
            section(document?.lineEnding.statusName ?? "Unix (LF)")
            section(document?.encodingName ?? "UTF-8")
            section("INS").help("Insert mode. Overwrite mode is not available.")
        }
        .font(.system(size: TidepadMetrics.statusFontSize)).monospacedDigit()
        .foregroundStyle(Color(nsColor: TidepadTheme.chromeText))
        .frame(height: TidepadMetrics.statusBarHeight)
        .background(Color(nsColor: TidepadTheme.statusBackground))
        .overlay(alignment: .top) { ChromeSeparator() }
    }

    /// The language, and for a large file, that it's one (and read-only when it isn't UTF-8).
    private static func kind(of document: EditorDocument) -> String {
        guard let buffer = document.largeBuffer else { return document.languageName }
        return buffer.isEditable ? "\(document.languageName) · large file" : "\(document.languageName) · large file · read-only: not UTF-8"
    }

    private func section(_ text: String) -> some View {
        HStack(spacing: 0) {
            ChromeSeparator(vertical: true).frame(height: TidepadMetrics.statusSeparatorHeight)
            Text(text).lineLimit(1).fixedSize().padding(.horizontal, TidepadMetrics.statusHorizontalPadding)
        }
    }
}
