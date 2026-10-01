import Foundation

/// UTF-16 offsets match AppKit. A shared reference avoids copying the offset array into the ruler.
final class LineIndex {
    private(set) var starts = [0]
    private var characterStarts = [0]
    private var characterCount = 0
    private var endings: [UInt8] = [0]
    private var crCount = 0
    private var crlfCount = 0
    private var length = 0
    var lineEnding: LineEnding { crlfCount > 0 ? .crlf : crCount > 0 ? .cr : .lf }

    struct Prepared: Sendable {
        let starts: [Int]
        let characterStarts: [Int]
        let characterCount: Int
        let endings: [UInt8]
        let length: Int
        let crCount: Int
        let crlfCount: Int
        var lineEnding: LineEnding { crlfCount > 0 ? .crlf : crCount > 0 ? .cr : .lf }
        init(_ text: String) {
            let parsed = LineIndex.parse(text, origin: 0)
            characterStarts = [0] + parsed.characters; characterCount = parsed.totalCharacters
            starts = [0] + parsed.starts; endings = parsed.endings + [0]
            length = (text as NSString).length
            crCount = parsed.endings.filter { $0 == 1 }.count
            crlfCount = parsed.endings.filter { $0 == 2 }.count
        }
    }

    func install(_ prepared: Prepared) {
        characterStarts = prepared.characterStarts; characterCount = prepared.characterCount
        starts = prepared.starts; endings = prepared.endings; length = prepared.length
        crCount = prepared.crCount; crlfCount = prepared.crlfCount
    }

    func rebuild(_ text: String) {
        install(Prepared(text))
    }

    /// The range is in the NEW storage coordinates, as supplied by NSTextStorage.
    /// Reparse adjacent complete lines to handle CR/LF joins and splits at either edit boundary.
    func applyEdit(in text: NSString, range: NSRange, delta: Int) {
        let oldEnd = range.location + range.length - delta
        let first = max(0, line(at: range.location) - 1)
        let after = min(starts.count, line(at: oldEnd) + 2)
        let begin = starts[first]
        let end = (after < starts.count ? starts[after] : length) + delta
        let parsed = Self.parse(text.substring(with: NSRange(location: begin, length: max(0, end - begin))), origin: begin)
        for kind in endings[first..<after] {
            if kind == 1 { crCount -= 1 }; if kind == 2 { crlfCount -= 1 }
        }
        let characterBegin = characterStarts[first]
        let characterEnd = after < starts.count ? characterStarts[after] : characterCount
        let characterDelta = parsed.totalCharacters - (characterEnd - characterBegin)
        var replacementCharacters = [characterBegin] + parsed.characters.map { $0 + characterBegin }
        var replacement = [begin] + parsed.starts
        var kinds = parsed.endings
        if after < starts.count { replacement.removeLast(); replacementCharacters.removeLast() } else { kinds.append(0) }
        // Contiguous offsets are deliberately retained: shifting 500k Ints is much cheaper than
        // scanning 50 MB of Unicode. This remains O(lines after edit), not a tree-based 1 GB index.
        if delta != 0 { for position in after..<starts.count { starts[position] += delta } }
        if characterDelta != 0 { for position in after..<characterStarts.count { characterStarts[position] += characterDelta } }
        characterStarts.replaceSubrange(first..<after, with: replacementCharacters)
        characterCount += characterDelta
        starts.replaceSubrange(first..<after, with: replacement)
        endings.replaceSubrange(first..<after, with: kinds)
        crCount += kinds.filter { $0 == 1 }.count
        crlfCount += kinds.filter { $0 == 2 }.count
        length = text.length
    }

    private static func parse(_ text: String, origin: Int) -> (starts: [Int], endings: [UInt8], characters: [Int], totalCharacters: Int) {
        var starts: [Int] = [], endings: [UInt8] = [], characters: [Int] = []
        var characterCount = 0, lineStart = 0
        var nonASCII = false
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            nonASCII = nonASCII || units[index] > 127
            if units[index] == 13 {
                let paired = index + 1 < units.count && units[index + 1] == 10
                if paired { index += 1 }
                starts.append(origin + index + 1); endings.append(paired ? 2 : 1)
            } else if units[index] == 10 || units[index] == 0x85 || units[index] == 0x2028 || units[index] == 0x2029 {
                // LF, and the other breaks the text system starts a new line at: NEL, line and paragraph separator.
                starts.append(origin + index + 1); endings.append(0)
            }
            if starts.last == origin + index + 1 {
                characterCount += nonASCII ? String(decoding: units[lineStart...index], as: UTF16.self).count : index + 1 - lineStart - (endings.last == 2 ? 1 : 0)
                characters.append(characterCount); lineStart = index + 1; nonASCII = false
            }
            index += 1
        }
        characterCount += nonASCII ? String(decoding: units[lineStart...], as: UTF16.self).count : units.count - lineStart
        return (starts, endings, characters, characterCount)
    }

    /// Complete interior lines use cached character counts; only the two edge fragments are read.
    func characters(in range: NSRange, text: NSString) -> Int {
        guard range.length > 0 else { return 0 }
        let first = line(at: range.location), last = line(at: NSMaxRange(range))
        if first == last { return text.substring(with: range).count }
        let head = text.substring(with: NSRange(location: range.location, length: starts[first + 1] - range.location)).count
        let tail = text.substring(with: NSRange(location: starts[last], length: NSMaxRange(range) - starts[last])).count
        return head + characterStarts[last] - characterStarts[first + 1] + tail
    }

    func line(at offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
}
