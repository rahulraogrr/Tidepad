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
struct TextEdit: Equatable {
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

    static func prettyJSON(_ text: String, indent: String, lineEnding: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var depth = 0, inString = false, escaped = false, index = 0
        func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" }
        func breakLine() {
            output.append(contentsOf: lineEnding.unicodeScalars)
            for _ in 0..<depth { output.append(contentsOf: indent.unicodeScalars) }
        }
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if inString {
                output.append(scalar)
                if escaped { escaped = false } else if scalar == "\\" { escaped = true } else if scalar == "\"" { inString = false }
                continue
            }
            switch scalar {
            case "\"":
                inString = true; output.append(scalar)
            case "{", "[":
                let close: Unicode.Scalar = scalar == "{" ? "}" : "]"
                var next = index
                while next < scalars.count && isSpace(scalars[next]) { next += 1 }
                output.append(scalar)
                if next < scalars.count && scalars[next] == close {
                    output.append(close); index = next + 1 // Keep {} and [] compact.
                } else {
                    depth += 1; breakLine()
                }
            case "}", "]":
                depth = max(0, depth - 1); breakLine(); output.append(scalar)
            case ",":
                output.append(scalar); breakLine()
            case ":":
                output.append(scalar); output.append(" ")
            default:
                if !isSpace(scalar) { output.append(scalar) }
            }
        }
        return String(output)
    }

    /// Re-indents well-formed XML. Comments, CDATA and element order are kept; an XML declaration
    /// is only present in the result if the original had one.
    static func formatXML(_ source: TextSource, selection: NSRange, lineEnding: String) throws -> TextEdit? {
        let scope = selection.length > 0 ? selection : NSRange(location: 0, length: source.length)
        let original = source.substring(with: scope)
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // XMLDocument can recover from some errors silently, so check well-formedness strictly first.
        let parser = XMLParser(data: Data(trimmed.utf8))
        guard parser.parse(), parser.parserError == nil else {
            let detail = parser.parserError.map { "Line \(parser.lineNumber): \($0.localizedDescription)" } ?? ""
            throw TextCommandFailure(errorDescription: "This isn’t well-formed XML. \(detail)")
        }
        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: trimmed, options: [.nodePreserveCDATA, .nodePreserveEmptyElements])
        } catch {
            throw TextCommandFailure(errorDescription: "This isn’t well-formed XML. \(error.localizedDescription)")
        }
        var text = document.xmlString(options: [.nodePrettyPrint, .nodePreserveCDATA, .nodePreserveEmptyElements])
        if !trimmed.hasPrefix("<?xml"), text.hasPrefix("<?xml"), let end = text.range(of: "?>") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .newlines)
        }
        text = lines(text).map(\.content).joined(separator: lineEnding)
        if let last = original.last, terminators.contains(last) { text += lineEnding }
        return formatted(scope, original: original, text: text, actionName: "Format XML")
    }

    private static func formatted(_ scope: NSRange, original: String, text: String, actionName: String) -> TextEdit? {
        guard text != original else { return nil }
        return TextEdit(range: scope, text: text, selection: NSRange(location: scope.location, length: 0), actionName: actionName)
    }
}
