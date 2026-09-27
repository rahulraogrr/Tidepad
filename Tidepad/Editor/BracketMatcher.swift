import Foundation

enum BracketMatcher {
    /// Bounds caret-movement work independently of document size. Strings/comments are not parsed.
    static func match(in text: NSString, caret: Int, limit: Int = 20_000) -> [NSRange] {
        guard caret >= 0 && caret <= text.length else { return [] }
        let opens: [UInt16] = [40, 91, 123]
        let closes: [UInt16] = [41, 93, 125]
        let candidates = [caret - 1, caret].filter { $0 >= 0 && $0 < text.length }
        guard let start = candidates.first(where: {
            opens.contains(text.character(at: $0)) || closes.contains(text.character(at: $0))
        }) else { return [] }
        let value = text.character(at: start)
        let forward = opens.contains(value)
        let entering = forward ? opens : closes
        let leaving = forward ? closes : opens
        var stack: [UInt16] = []
        var position = start
        var visited = 0
        while position >= 0 && position < text.length && visited < limit {
            let unit = text.character(at: position)
            if let kind = entering.firstIndex(of: unit) { stack.append(leaving[kind]) }
            else if leaving.contains(unit) {
                guard stack.last == unit else { return [] }
                stack.removeLast()
                if stack.isEmpty {
                    return [NSRange(location: start, length: 1), NSRange(location: position, length: 1)]
                }
            }
            position += forward ? 1 : -1
            visited += 1
        }
        return []
    }
}
