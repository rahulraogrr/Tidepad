import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The read access text commands need. NSString provides it today; a future chunked storage engine
/// can conform too, so commands never have to materialise the whole document as one String.
protocol TextSource {
    var length: Int { get }
    func substring(with range: NSRange) -> String
    func lineRange(for range: NSRange) -> NSRange
}

extension NSString: TextSource {}

/// One replacement produced by a text command, applied by the editor as a single undoable edit.
struct TextEdit: Equatable, Sendable {
    let range: NSRange
    let text: String
    let selection: NSRange
    let actionName: String
}

enum CaseConversion: Sendable {
    case upper, lower, title

    var actionName: String {
        switch self {
        case .upper: return "Convert to Uppercase"
        case .lower: return "Convert to Lowercase"
        case .title: return "Convert to Title Case"
        }
    }
}

struct TextCommandFailure: LocalizedError {
    let errorDescription: String?
}

/// Pure, range-based editing commands. Each returns the edit to apply, or nil when there is nothing
/// to do, so a no-op never marks the document as changed.
enum TextCommands {
    private static let terminators: Set<Character> = ["\r\n", "\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"]

    // MARK: Line structure

    /// The whole lines a selection touches. A selection that ends at the start of a line
    /// (e.g. after selecting full lines with the mouse) does not include that next line.
    static func lineBlock(_ source: TextSource, selection: NSRange) -> NSRange {
        var range = selection
        if range.length > 0 {
            let end = NSMaxRange(range)
            if source.lineRange(for: NSRange(location: end, length: 0)).location == end { range.length -= 1 }
        }
        return source.lineRange(for: range)
    }

    static func splitTerminator(_ line: String) -> (content: String, terminator: String) {
        guard let last = line.last, terminators.contains(last) else { return (line, "") }
        return (String(line.dropLast()), String(last))
    }

    /// Lines with their own terminators; the last line's terminator is empty when the text doesn't end with one.
    static func lines(_ text: String) -> [(content: String, terminator: String)] {
        let ns = text as NSString
        var result: [(content: String, terminator: String)] = []
        var location = 0
        while location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            result.append(splitTerminator(ns.substring(with: range)))
            location = NSMaxRange(range)
        }
        return result
    }

    /// Joins contents keeping the original terminators by position, so a block that didn't end
    /// with a line break still doesn't, and mixed line endings are not rewritten.
    private static func join(_ contents: [String], terminators: [String], fallback: String) -> String {
        var output = ""
        for (index, content) in contents.enumerated() {
            output += content
            if index == contents.count - 1 { output += terminators.last ?? "" }
            else { output += terminators[index].isEmpty ? fallback : terminators[index] }
        }
        return output
    }

    /// Selected lines, or the whole document when nothing is selected (as in Notepad++).
    private static func linesScope(_ source: TextSource, selection: NSRange) -> NSRange {
        selection.length > 0 ? lineBlock(source, selection: selection) : NSRange(location: 0, length: source.length)
    }

    private static func length(_ text: String) -> Int { (text as NSString).length }

    // MARK: Edit menu

    static func duplicateLines(_ source: TextSource, selection: NSRange, lineEnding: String) -> TextEdit {
        let block = lineBlock(source, selection: selection)
        let text = source.substring(with: block)
        let insertion = splitTerminator(text).terminator.isEmpty ? lineEnding + text : text
        return TextEdit(range: NSRange(location: NSMaxRange(block), length: 0), text: insertion,
                        selection: selection, actionName: "Duplicate Line")
    }

    static func deleteLines(_ source: TextSource, selection: NSRange) -> TextEdit? {
        guard source.length > 0 else { return nil }
        var block = lineBlock(source, selection: selection)
        var caret = block.location
        if splitTerminator(source.substring(with: block)).terminator.isEmpty && block.location > 0 {
            // The last line has no line break: remove the previous line's break instead,
            // so deleting it doesn't leave an empty line behind.
            let previous = source.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let breakLength = length(splitTerminator(source.substring(with: previous)).terminator)
            block = NSRange(location: block.location - breakLength, length: block.length + breakLength)
            caret = previous.location
        }
        guard block.length > 0 else { return nil }
        return TextEdit(range: block, text: "", selection: NSRange(location: caret, length: 0),
                        actionName: "Delete Line")
    }

    static func moveLines(_ source: TextSource, selection: NSRange, up: Bool) -> TextEdit? {
        let block = lineBlock(source, selection: selection)
        let neighbour: NSRange
        if up {
            guard block.location > 0 else { return nil }
            neighbour = source.lineRange(for: NSRange(location: block.location - 1, length: 0))
        } else {
            guard NSMaxRange(block) < source.length else { return nil }
            neighbour = source.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        }
        let first = up ? neighbour : block, second = up ? block : neighbour
        let a = splitTerminator(source.substring(with: first))
        let b = splitTerminator(source.substring(with: second))
        // Swap the contents; the line breaks stay where they were.
        let text = b.content + a.terminator + a.content + b.terminator
        let region = NSRange(location: first.location, length: NSMaxRange(second) - first.location)
        let blockStart = up ? region.location : region.location + length(b.content) + length(a.terminator)
        return TextEdit(range: region, text: text,
                        selection: NSRange(location: blockStart + selection.location - block.location, length: selection.length),
                        actionName: up ? "Move Line Up" : "Move Line Down")
    }

    // MARK: Tools menu

    static func convertCase(_ source: TextSource, selection: NSRange, to conversion: CaseConversion) -> TextEdit? {
        guard selection.length > 0 else { return nil }
        let original = source.substring(with: selection)
        let converted: String
        switch conversion {
        case .upper: converted = original.uppercased()
        case .lower: converted = original.lowercased()
        case .title: converted = original.capitalized
        }
        guard converted != original else { return nil }
        return TextEdit(range: selection, text: converted,
                        selection: NSRange(location: selection.location, length: length(converted)),
                        actionName: conversion.actionName)
    }

    static func sortLines(_ source: TextSource, selection: NSRange, ascending: Bool, lineEnding: String) -> TextEdit? {
        rewriteLines(source, selection: selection, lineEnding: lineEnding,
                     actionName: ascending ? "Sort Lines Ascending" : "Sort Lines Descending") { contents in
            contents.sorted { ascending ? $0 < $1 : $0 > $1 }
        }
    }

    /// Keeps the first occurrence of each line, anywhere in the scope (not only adjacent repeats).
    static func removeDuplicateLines(_ source: TextSource, selection: NSRange, lineEnding: String) -> TextEdit? {
        rewriteLines(source, selection: selection, lineEnding: lineEnding, actionName: "Remove Duplicate Lines") { contents in
            var seen = Set<String>()
            return contents.filter { seen.insert($0).inserted }
        }
    }

    private static func rewriteLines(_ source: TextSource, selection: NSRange, lineEnding: String, actionName: String,
                                     _ transform: ([String]) -> [String]) -> TextEdit? {
        let scope = linesScope(source, selection: selection)
        let original = source.substring(with: scope)
        let parts = lines(original)
        guard parts.count > 1 else { return nil }
        let text = join(transform(parts.map(\.content)), terminators: parts.map(\.terminator), fallback: lineEnding)
        guard text != original else { return nil }
        let result = selection.length > 0
            ? NSRange(location: scope.location, length: length(text))
            : NSRange(location: min(selection.location, length(text)), length: 0)
        return TextEdit(range: scope, text: text, selection: result, actionName: actionName)
    }

    // MARK: Formatting

    /// Pretty-prints the selection, or the whole document. Key order, number spelling and string
    /// escapes are kept exactly; only whitespace between tokens changes.
    static func formatJSON(_ source: TextSource, selection: NSRange, indent: String, lineEnding: String) throws -> TextEdit? {
        let scope = selection.length > 0 ? selection : NSRange(location: 0, length: source.length)
        let original = source.substring(with: scope)
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(original.utf8), options: [.fragmentsAllowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw TextCommandFailure(errorDescription: "This isn’t valid JSON. \(detail)")
        }
        var text = prettyJSON(original, indent: indent, lineEnding: lineEnding)
        if let last = original.last, terminators.contains(last) { text += lineEnding }
        return formatted(scope, original: original, text: text, actionName: "Format JSON")
    }

    /// One pass over the UTF-8 bytes into a byte buffer. JSON's structure is all ASCII, so string
    /// contents (any UTF-8) are copied byte for byte; output grows by amortised appends only.
    static func prettyJSON(_ text: String, indent: String, lineEnding: String) -> String {
        let input = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count + input.count / 2)
        let indentBytes = Array(indent.utf8), newline = Array(lineEnding.utf8)
        var depth = 0, inString = false, escaped = false, index = 0
        @inline(__always) func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        func breakLine() {
            output.append(contentsOf: newline)
            for _ in 0..<depth { output.append(contentsOf: indentBytes) }
        }
        while index < input.count {
            let byte = input[index]
            index += 1
            if inString {
                output.append(byte)
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: // "
                inString = true; output.append(byte)
            case 0x7B, 0x5B: // { [
                let close: UInt8 = byte == 0x7B ? 0x7D : 0x5D
                var next = index
                while next < input.count && isSpace(input[next]) { next += 1 }
                output.append(byte)
                if next < input.count && input[next] == close {
                    output.append(close); index = next + 1 // Keep {} and [] compact.
                } else {
                    depth += 1; breakLine()
                }
            case 0x7D, 0x5D: // } ]
                depth = max(0, depth - 1); breakLine(); output.append(byte)
            case 0x2C: // ,
                output.append(byte); breakLine()
            case 0x3A: // :
                output.append(byte); output.append(0x20)
            default:
                if !isSpace(byte) { output.append(byte) }
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Re-indents well-formed XML. Comments, CDATA and element order are kept; an XML declaration
    /// is only present in the result if the original had one.
    static func formatXML(_ source: TextSource, selection: NSRange, lineEnding: String) throws -> TextEdit? {
        let scope = selection.length > 0 ? selection : NSRange(location: 0, length: source.length)
        let original = source.substring(with: scope)
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The text is already decoded, so an encoding="ISO-8859-1" declaration mustn't make the parser
        // read it again as Latin-1 (café would become cafÃ©): it's parsed as UTF-8, and the original
        // declaration is put back exactly as it was.
        let declaration = Self.xmlDeclaration(trimmed)
        let body = declaration.map { String(trimmed[$0.upperBound...]) } ?? trimmed
        // XMLDocument can recover from some errors silently, so check well-formedness strictly first.
        let parser = XMLParser(data: Data(body.utf8))
        guard parser.parse(), parser.parserError == nil else {
            let detail = parser.parserError.map { "Line \(parser.lineNumber): \($0.localizedDescription)" } ?? ""
            throw TextCommandFailure(errorDescription: "This isn’t well-formed XML. \(detail)")
        }
        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: body, options: Self.xmlOptions)
        } catch {
            throw TextCommandFailure(errorDescription: "This isn’t well-formed XML. \(error.localizedDescription)")
        }
        var text = document.xmlString(options: Self.xmlOptions.union(.nodePrettyPrint))
        if text.hasPrefix("<?xml"), let end = text.range(of: "?>") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .newlines)
        }
        if let declaration { text = String(trimmed[declaration]) + "\n" + text }
        text = lines(text).map(\.content).joined(separator: lineEnding)
        if let last = original.last, terminators.contains(last) { text += lineEnding }
        return formatted(scope, original: original, text: text, actionName: "Format XML")
    }

    /// Character references (&#169;) are kept as written where XMLDocument can. (Not .nodePreserveEntities:
    /// on macOS it writes &amp; back as a bare &, which isn't XML.)
    private static let xmlOptions: XMLNode.Options = [.nodePreserveCDATA, .nodePreserveEmptyElements,
                                                      .nodePreserveCharacterReferences, .nodePreserveAttributeOrder]

    /// The `<?xml … ?>` declaration at the start, if there is one.
    private static func xmlDeclaration(_ text: String) -> Range<String.Index>? {
        guard text.hasPrefix("<?xml"), let end = text.range(of: "?>") else { return nil }
        return text.startIndex..<end.upperBound
    }

    /// Formats SQL in the style of the "SQL Formatter" VS Code extension (sql-formatter-plus).
    static func formatSQL(_ source: TextSource, selection: NSRange, indent: String, lineEnding: String,
                          uppercase: Bool = false) throws -> TextEdit? {
        let scope = selection.length > 0 ? selection : NSRange(location: 0, length: source.length)
        let original = source.substring(with: scope)
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let normalized = original.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard var text = SQLFormatter.formatChecked(normalized, options: .init(indent: indent, uppercase: uppercase)) else {
            throw TextCommandFailure(errorDescription: "TidePad couldn’t format this SQL without risking a change to what it means, so it was left as it is.")
        }
        if lineEnding != "\n" { text = text.replacingOccurrences(of: "\n", with: lineEnding) }
        if let last = original.last, terminators.contains(last) { text += lineEnding }
        return formatted(scope, original: original, text: text, actionName: "Format SQL")
    }

    private static func formatted(_ scope: NSRange, original: String, text: String, actionName: String) -> TextEdit? {
        guard text != original else { return nil }
        return TextEdit(range: scope, text: text, selection: NSRange(location: scope.location, length: 0), actionName: actionName)
    }
}
