import Foundation

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

    // Initialisers NSString requires every subclass to provide; a PieceTableString is only ever made
    // from a table.
    required init?(coder: NSCoder) { fatalError("PieceTableString is not archivable") }
    #if os(Linux)
    // swift-corelibs-foundation (used only to run the Foundation checks on Linux).
    required convenience init(string aString: String) { fatalError("Not supported") }
    required convenience init(unicodeScalarLiteral value: StaticString) { fatalError("Not supported") }
    required convenience init(extendedGraphemeClusterLiteral value: StaticString) { fatalError("Not supported") }
    required convenience init(stringLiteral value: StaticString) { fatalError("Not supported") }
    #else
    required convenience init(itemProviderData data: Data, typeIdentifier: String) throws { fatalError("Not supported") }
    required convenience init(unicodeScalarLiteral value: StaticString) { fatalError("Not supported") }
    required convenience init(extendedGraphemeClusterLiteral value: StaticString) { fatalError("Not supported") }
    required convenience init(stringLiteral value: StaticString) { fatalError("Not supported") }
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
