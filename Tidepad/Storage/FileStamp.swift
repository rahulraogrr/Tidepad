import Foundation

/// Identifies one version of a file on disk (modification date, size and file number), so real changes
/// by other apps can be told apart from metadata-only notifications and from Tidepad's own saves.
///
/// Symbolic links are followed: the stamp describes the file a link points to (a dotfile linked from a
/// repository, say), since that's what's read and written.
struct FileStamp: Equatable, Codable, Sendable {
    let modified: Date?
    let size: Int?
    /// The file's number on its volume. A file replaced by another (an atomic save, a checkout) has a
    /// new one, even with the same date and size.
    let fileID: UInt64?

    /// nil when the file doesn't exist (or can't be inspected).
    init?(_ url: URL) {
        var target = url.resolvingSymlinksInPath()
        target.removeAllCachedResourceValues()
        var keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        #if os(macOS)
        keys.insert(.fileIdentifierKey)
        #endif
        guard let values = try? target.resourceValues(forKeys: keys),
              values.contentModificationDate != nil || values.fileSize != nil else { return nil }
        modified = values.contentModificationDate
        size = values.fileSize
        #if os(macOS)
        fileID = values.fileIdentifier
        #else
        fileID = nil
        #endif
    }

    /// A stamp recorded earlier (the session keeps them across launches).
    init(modified: Date?, size: Int?, fileID: UInt64? = nil) {
        self.modified = modified
        self.size = size
        self.fileID = fileID
    }

    /// The same version: same date and size, and the same file number when both stamps have one
    /// (stamps saved by earlier versions of Tidepad don't).
    static func == (a: FileStamp, b: FileStamp) -> Bool {
        guard a.modified == b.modified, a.size == b.size else { return false }
        if let first = a.fileID, let second = b.fileID { return first == second }
        return true
    }
}
