import Foundation

struct SearchResultBuilder {
    private let text: NSString
    private var lineStart = 0
    private var lineEnd = 0
    private var contentsEnd = 0
    private var line = 1
    private var loaded = false
    private var columnOffset = 0
    private var column = 1
    init(_ source: SearchSnapshot) { text = source.text as NSString }

    /// Advance once per logical line using Foundation's Unicode-aware line boundaries.
    mutating func result(_ range: NSRange, documentID: UUID?, url: URL?, name: String,
                         revision: UInt64?, fileDate: Date? = nil, fileSize: Int? = nil) -> SearchResult {
        if !loaded { loadLine(at: 0); loaded = true }
        while range.location >= lineEnd && lineEnd > lineStart {
            if lineEnd == text.length && contentsEnd == lineEnd { break }
            let next = lineEnd; line += 1; loadLine(at: next)
        }
        let start = min(lineStart, range.location)
        // Count each complete grapheme once, including on very long single-line files.
        let boundary = range.location == text.length ? text.length : text.rangeOfComposedCharacterSequence(at: range.location).location
        let safeOffset = max(start, boundary)
        if safeOffset >= columnOffset {
            column += text.substring(with: NSRange(location: columnOffset, length: safeOffset - columnOffset)).count
            columnOffset = safeOffset
        }
        let resultColumn = column + text.substring(with: NSRange(location: safeOffset, length: range.location - safeOffset)).count
        let previewStart = max(start, range.location - 80)
        let previewEnd = min(contentsEnd, previewStart + 240)
        let previewRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: previewStart, length: max(0, previewEnd - previewStart)))
        return SearchResult(documentID: documentID, url: url, name: name, revision: revision, range: range,
                            line: line, column: resultColumn,
                            preview: text.substring(with: previewRange), fileDate: fileDate, fileSize: fileSize)
    }
    private mutating func loadLine(at offset: Int) {
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
        columnOffset = lineStart; column = 1
    }
}
