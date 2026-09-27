import Foundation

/// A line-by-line comparison of two texts, for reviewing Claude Code's proposed changes. Uses the Swift
/// standard library's `difference(from:)` (Myers' algorithm) on the lines.
enum LineDiff {
    enum Line: Equatable {
        case same(String, old: Int, new: Int)
        case removed(String, old: Int)
        case added(String, new: Int)
    }

    /// Every line of both texts in order: removals before additions where lines were replaced. Line
    /// numbers are 1-based.
    static func lines(old: String, new: String) -> [Line] {
        let oldLines = split(old), newLines = split(new)
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count && removed.contains(i) {
                result.append(.removed(oldLines[i], old: i + 1)); i += 1
            } else if j < newLines.count && inserted.contains(j) {
                result.append(.added(newLines[j], new: j + 1)); j += 1
            } else if i < oldLines.count && j < newLines.count {
                result.append(.same(oldLines[i], old: i + 1, new: j + 1)); i += 1; j += 1
            } else {
                break // Unreachable for a consistent difference.
            }
        }
        return result
    }

    /// The changed lines with `context` unchanged lines around each change; nil marks a gap.
    static func hunks(_ lines: [Line], context: Int = 3) -> [Line?] {
        let changed = lines.indices.filter { if case .same = lines[$0] { return false }; return true }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed { keep.formUnion(max(0, index - context)...min(lines.count - 1, index + context)) }
        var result: [Line?] = []
        var previous: Int?
        for index in keep.sorted() {
            if let previous, index > previous + 1 { result.append(nil) }
            if previous == nil && index > 0 { result.append(nil) }
            result.append(lines[index])
            previous = index
        }
        if let previous, previous < lines.count - 1 { result.append(nil) }
        return result
    }

    /// Counts of added and removed lines.
    static func summary(_ lines: [Line]) -> (added: Int, removed: Int) {
        lines.reduce(into: (0, 0)) { counts, line in
            if case .added = line { counts.0 += 1 }
            if case .removed = line { counts.1 += 1 }
        }
    }

    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // Swift treats CR LF as one Character, so split on any line break rather than on "\n".
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if text.last?.isNewline == true { lines.removeLast() }
        return lines
    }
}
