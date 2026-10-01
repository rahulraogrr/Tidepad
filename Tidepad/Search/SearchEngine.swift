import Foundation

/// Immutable compiled query, safe to reuse between workers. No UI or document ownership.
final class SearchEngine: @unchecked Sendable {
    let query: SearchQuery
    private let literal: String
    private let regex: NSRegularExpression?

    init(_ query: SearchQuery) throws {
        guard !query.text.isEmpty else { throw SearchFailure.empty }
        self.query = query
        literal = query.mode == .extended ? try Self.decode(query.text) : query.text
        regex = try Self.expression(for: query, literal: literal)
    }

    /// The regular expression a query needs (regular-expression mode, or Whole word), or nil for a
    /// plain search. As in Notepad++, ^ and $ match at the start and end of every line. The large-file
    /// view uses the same expression (LargeTextSearch), so both editors find the same matches.
    static func expression(for query: SearchQuery, literal: String) throws -> NSRegularExpression? {
        guard query.mode == .regex || query.wholeWord else { return nil }
        var pattern = query.mode == .regex ? query.text : NSRegularExpression.escapedPattern(for: literal)
        if query.wholeWord { pattern = "(?<![\\p{L}\\p{N}\\p{M}_])(?:\(pattern))(?![\\p{L}\\p{N}\\p{M}_])" }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !query.matchCase { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: options)
    }

    /// A regular-expression replacement as Notepad++ reads it: \n, \r and \t are a line break, return
    /// and tab (NSRegularExpression would insert the letter), while \\, \$ and $1 keep their template meaning.
    static func regexTemplate(_ template: String) -> String {
        guard template.contains("\\") else { return template }
        var result = "", escaped = false
        for character in template {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append("\\"); result.append(character) // \\ and \$ stay escapes for the template.
                }
                escaped = false
            } else if character == "\\" { escaped = true } else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }

    static func decode(_ text: String) throws -> String {
        var result = "", escaped = false
        for character in text {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "0": result.append("\0")
                case "\\": result.append("\\")
                default: throw SearchFailure.invalidEscape
                }
                escaped = false
            } else if character == "\\" { escaped = true } else { result.append(character) }
        }
        if escaped { throw SearchFailure.invalidEscape }
        return result
    }

    func next(_ source: any SearchTextSource, from offset: Int, backwards: Bool = false,
              excluding: NSRange? = nil, cancelled: () -> Bool = { false }) -> SearchMatch? {
        source.nextMatch(using: self, from: offset, backwards: backwards, excluding: excluding, cancelled: cancelled)
    }

    func enumerate(_ source: any SearchTextSource, range: NSRange? = nil,
                   cancelled: () -> Bool = { false }, visit: (NSRange, NSTextCheckingResult?) -> Bool) {
        source.enumerateMatches(using: self, range: range, cancelled: cancelled, visit: visit)
    }

    /// Streaming enumeration; consumers can stop without retaining all occurrences.
    func enumerateSnapshot(_ source: SearchSnapshot, range: NSRange? = nil,
                   cancelled: () -> Bool = { false }, visit: (NSRange, NSTextCheckingResult?) -> Bool) {
        let ns = source.text as NSString
        let bounds = range ?? NSRange(location: 0, length: ns.length)
        guard bounds.location >= 0, NSMaxRange(bounds) <= ns.length, !cancelled() else { return }
        if let regex {
            regex.enumerateMatches(in: source.text, options: [.reportProgress, .withTransparentBounds, .withoutAnchoringBounds], range: bounds) { match, _, stop in
                if cancelled() { stop.pointee = true; return }
                if let match, !visit(match.range, match) { stop.pointee = true }
            }
        } else {
            var start = bounds.location
            let options: NSString.CompareOptions = query.matchCase ? [.literal] : [.caseInsensitive, .literal]
            while start <= NSMaxRange(bounds), !cancelled() {
                let found = ns.range(of: literal, options: options, range: NSRange(location: start, length: NSMaxRange(bounds) - start))
                if found.location == NSNotFound { break }
                if !visit(found, nil) { break }
                start = NSMaxRange(found)
            }
        }
    }

    func nextSnapshot(_ source: SearchSnapshot, from offset: Int, backwards: Bool = false,
              excluding: NSRange? = nil, cancelled: () -> Bool = { false }) -> SearchMatch? {
        let timing = SearchTiming(backwards ? "Find Previous" : "Find Next"); defer { timing.finish() }
        let ns = source.text as NSString
        let position = min(max(0, offset), ns.length)
        func locate(_ range: NSRange) -> NSRange? {
            if regex == nil && backwards {
                var options: NSString.CompareOptions = [.backwards, .literal]
                if !query.matchCase { options.insert(.caseInsensitive) }
                let match = ns.range(of: literal, options: options, range: range)
                return match.location == NSNotFound ? nil : match
            }
            var found: NSRange?
            enumerate(source, range: range, cancelled: cancelled) { range, _ in
                if range == excluding { return true }
                found = range
                return backwards
            }
            return found
        }
        let primary = backwards ? NSRange(location: 0, length: position) : NSRange(location: position, length: ns.length - position)
        if let found = locate(primary) { return SearchMatch(range: found) }
        guard query.wrap, !cancelled() else { return nil }
        let wrapped = backwards ? NSRange(location: position, length: ns.length - position) : NSRange(location: 0, length: position)
        return locate(wrapped).map { SearchMatch(range: $0) }
    }

    func matches(_ source: SearchSnapshot, range: NSRange? = nil, limit: Int = 100_000,
                 cancelled: () -> Bool = { false }) -> (ranges: [NSRange], truncated: Bool) {
        var ranges: [NSRange] = [], truncated = false
        enumerate(source, range: range, cancelled: cancelled) { match, _ in
            guard ranges.count < limit else { truncated = true; return false }
            ranges.append(match); return true
        }
        return (ranges, truncated)
    }

    struct Replacement: Sendable { let range: NSRange; let text: String; let count: Int }
    func replacement(_ source: SearchSnapshot, template: String, range: NSRange? = nil,
                     exact: Bool = false, cancelled: () -> Bool = { false }) throws -> Replacement? {
        let timing = SearchTiming("Replace All plan"); defer { timing.finish() }
        let ns = source.text as NSString
        let bounds = range ?? NSRange(location: 0, length: ns.length)
        let replacement = query.mode == .extended ? try Self.decode(template) : query.mode == .regex ? Self.regexTemplate(template) : template
        var edits: [(NSRange, String)] = []
        var overflow = false
        enumerate(source, range: bounds, cancelled: cancelled) { match, checking in
            if exact && match != bounds { return true }
            if edits.count == 100_000 { overflow = true; return false }
            let value: String
            if query.mode == .regex, let regex, let checking {
                value = regex.replacementString(for: checking, in: source.text, offset: 0, template: replacement)
            } else { value = replacement }
            edits.append((match, value)); return !exact
        }
        if cancelled() { throw CancellationError() }
        if overflow { throw SearchFailure.tooManyReplacements }
        guard let first = edits.first, let last = edits.last else { return nil }
        let affected = NSRange(location: first.0.location, length: NSMaxRange(last.0) - first.0.location)
        // One replacement string is unavoidable for one atomic NSTextView undo transaction.
        var output = "", cursor = affected.location
        for (match, value) in edits {
            if cancelled() { throw CancellationError() }
            output += ns.substring(with: NSRange(location: cursor, length: match.location - cursor))
            output += value; cursor = NSMaxRange(match)
        }
        output += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(affected) - cursor))
        return Replacement(range: affected, text: output, count: edits.count)
    }
}
