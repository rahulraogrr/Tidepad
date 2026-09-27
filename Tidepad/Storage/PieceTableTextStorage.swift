import AppKit

/// An NSTextStorage backed by a PieceTable, so NSTextView edits a document that is never held in
/// memory as one string. Apple documents NSTextStorage subclassing: a subclass provides `string`,
/// `attributes(at:effectiveRange:)`, `replaceCharacters(in:with:)` and `setAttributes(_:range:)`, and
/// reports changes with `edited(_:range:changeInLength:)`.
///
/// Prototype scope: one uniform set of attributes (font, paragraph style, colour) for all text.
/// Per-range attributes (syntax bold) come later, stored as runs rather than per character.
final class PieceTableTextStorage: NSTextStorage {
    let table: PieceTable
    private let backing: PieceTableString
    private var uniformAttributes: [NSAttributedString.Key: Any]

    init(table: PieceTable, attributes: [NSAttributedString.Key: Any]) {
        self.table = table
        backing = PieceTableString(table: table)
        uniformAttributes = attributes
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Not archivable") }
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("Not supported")
    }

    /// Bridging calls copy(), which PieceTableString answers with an O(pieces) snapshot, not 500 MB.
    override var string: String { backing as String }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        range?.pointee = NSRange(location: 0, length: backing.length)
        return uniformAttributes
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        table.replace(range, with: Array(str.utf16))
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        // Uniform attributes: NSTextView re-applies its typing attributes to inserted text, which are
        // the same set; merge so font or paragraph changes apply everywhere.
        if let attrs { uniformAttributes.merge(attrs) { _, new in new } }
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }
}
