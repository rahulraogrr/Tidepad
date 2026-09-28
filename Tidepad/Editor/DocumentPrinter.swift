import AppKit

/// File ▸ Print: prints a document through AppKit's print system, so the standard print panel works
/// as in any Mac app, including its PDF menu for saving a PDF. The text is printed in the editor's
/// font, wrapped to the page, with its syntax colours as the Light theme shows them (dark text on
/// white paper, whatever theme is on screen), and the file name and page numbers in the header and
/// footer.
@MainActor enum DocumentPrinter {
    /// Documents larger than this print without syntax colours, which would take a while to work out.
    static let maximumColouredLength = 5_000_000

    /// The document's text, ready to print: the editor font and tab stops, black text, and the Light
    /// theme's syntax colours and bold keywords.
    static func printableText(_ text: NSString, index: LineIndex, language: SyntaxLanguage, font: NSFont,
                              paragraph: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text as String, attributes: [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph
        ])
        guard language != .plain, text.length > 0, text.length <= maximumColouredLength else { return result }
        var engine = IncrementalSyntaxEngine(language: language)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        result.beginEditing()
        for token in engine.tokens(in: NSRange(location: 0, length: text.length), index: index, text: text) {
            result.addAttribute(.foregroundColor, value: SyntaxPalette.color(for: token.kind, language: language, dark: false), range: token.range)
            if SyntaxPalette.isBold(token.kind) { result.addAttribute(.font, value: bold, range: token.range) }
        }
        result.endEditing()
        return result
    }

    /// Shows the print panel for a document, as a sheet on the window.
    static func print(_ session: EditorSession, font: NSFont, window: NSWindow?) {
        guard let storage = session.textView.textStorage else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true

        let paragraph = session.textView.defaultParagraphStyle ?? .default
        let text = printableText(storage.mutableString, index: session.index, language: session.document.syntaxLanguage,
                                 font: font, paragraph: paragraph)
        let width = max(100, info.paperSize.width - info.leftMargin - info.rightMargin)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.appearance = NSAppearance(named: .aqua)
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = session.document.displayName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
