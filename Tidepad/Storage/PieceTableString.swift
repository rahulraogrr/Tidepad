import Foundation
#if canImport(AppKit)
import AppKit // NSString's pasteboard initialiser (below) comes from AppKit.
#endif

/// An NSString backed by a PieceTable. NSString is a class cluster that Apple documents for
/// subclassing: the primitives are `length` and `character(at:)`, and overriding
/// `getCharacters(_:range:)` gives TextKit fast bulk access. This lets NSTextView work on a document
/// whose text is never held in memory as one contiguous string.
final class PieceTableString: NSString, @unchecked Sendable {
    let table: PieceTable

    init(table: PieceTable) {
        self.table = table
        #if os(Linux)
        var none: unichar = 0
        super.init(characters: &none, length: 0) // swift-corelibs-foundation doesn't export init().
        #else
        super.init()
        #endif
    }

    // Initialisers. On macOS a subclass inherits NSString's required convenience initialisers
    // (e.g. init(stringLiteral:), declared in an extension and so not overridable) only by providing
    // all of NSString's designated ones: init(), init?(coder:) and AppKit's pasteboard initialiser.
    #if os(Linux)
    required init?(coder: NSCoder) { fatalError("PieceTableString is not archivable") }
    // swift-corelibs-foundation (used only to run the Foundation checks on Linux).
    required convenience init(string aString: String) { fatalError("Not supported") }
    required convenience init(unicodeScalarLiteral value: StaticString) { fatalError("Not supported") }
    required convenience init(extendedGraphemeClusterLiteral value: StaticString) { fatalError("Not supported") }
    required convenience init(stringLiteral value: StaticString) { fatalError("Not supported") }
    #else
    /// An empty string (NSString's designated initialiser).
    override init() {
        table = PieceTable(original: .empty)
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("PieceTableString is not archivable") }
    required init(itemProviderData data: Data, typeIdentifier: String) throws { fatalError("Not supported") }
    #if canImport(AppKit)
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("Not supported")
    }
    #endif
    #endif

    // The two NSString primitives.
    override var length: Int { table.length }
    override func character(at index: Int) -> unichar { table.character(at: index) }

    #if !os(Linux)
    /// Bulk access, used heavily by TextKit. (Not overridable in swift-corelibs-foundation.)
    override func getCharacters(_ buffer: UnsafeMutablePointer<unichar>, range: NSRange) {
        table.getCharacters(buffer, range: range)
    }
    #endif

    /// A copy must not follow later edits, but must not duplicate 500 MB either: Swift calls copy()
    /// whenever it bridges an NSString to String. A frozen piece-table snapshot is O(pieces).
    override func copy(with zone: NSZone? = nil) -> Any {
        table.isFrozen ? self : PieceTableString(table: table.snapshot())
    }
}
