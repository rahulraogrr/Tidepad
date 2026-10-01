import Foundation

/// What Tidepad can ask the on-device model (OnDeviceModel) to do.
enum AIRequest: Equatable, Sendable {
    case explain
    case summarise
    case rewrite(AIRewriteStyle)
    /// A regular expression for a description in words.
    case regex(String)

    var title: String {
        switch self {
        case .explain: return "Explain"
        case .summarise: return "Summarise"
        case .rewrite(let style): return style.rawValue
        case .regex: return "Write Regular Expression"
        }
    }
}

enum AIRewriteStyle: String, CaseIterable, Sendable {
    case grammar = "Fix Spelling and Grammar"
    case shorter = "Make Shorter"
    case list = "Make a List"
}

/// The instructions and prompt for a request, with the text it's about cut to fit the model.
///
/// Apple's on-device model has a context of about 4,096 tokens for instructions, prompt and answer
/// together, so the text is limited to `inputLimit` characters (roughly 2,000–2,700 tokens of prose or
/// code), cut at a line break where there is one.
struct AIPrompt: Equatable, Sendable {
    static let inputLimit = 8_000

    let instructions: String
    let prompt: String
    /// Whether the text was cut to fit.
    let clipped: Bool
    /// The text the model is given: all of it, or its start when it was cut to fit.
    let usedText: String

    private static let role = "You are a helpful assistant inside TidePad, a text and code editor for developers. Be accurate and concise. Don't use Markdown headings."

    init(_ request: AIRequest, text: String, language: String? = nil) {
        let (input, clipped) = Self.clip(text)
        self.clipped = clipped
        usedText = input
        let kind = language.map { " (\($0))" } ?? ""
        switch request {
        case .explain:
            instructions = Self.role + " Explain what the text you're given does or means. For code, explain what it does and anything surprising. For a log line or an error message, explain what it means and its likely cause. Keep it under 150 words."
            prompt = "Explain this\(kind):\n\n\(input)"
        case .summarise:
            instructions = Self.role + " Summarise the text you're given in at most 6 short bullet points, each starting with \"- \". Point out anything that looks like an error or a problem."
            prompt = "Summarise this\(kind):\n\n\(input)"
        case .rewrite(let style):
            let task: String
            switch style {
            case .grammar: task = "Rewrite the text you're given with its spelling and grammar corrected. Keep its meaning, tone and line breaks."
            case .shorter: task = "Rewrite the text you're given to be shorter and clearer, keeping all of its meaning."
            case .list: task = "Rewrite the text you're given as a list, one point per line, each starting with \"- \"."
            }
            instructions = Self.role + " " + task + " Reply with only the rewritten text: nothing before or after it, and no quotes or code fences around it."
            prompt = input
        case .regex(let description):
            instructions = "You write regular expressions in ICU syntax, as used by Apple's NSRegularExpression. ^ and $ match at the start and end of every line. Reply with only the regular expression, on one line, with no quotes, backticks, slashes or explanation."
            prompt = "A regular expression that finds: \(description)"
        }
    }

    /// `text`, cut to `limit` characters at the last line break before it (or at the limit, if the
    /// text has no line break there), and whether it was cut.
    static func clip(_ text: String, limit: Int = inputLimit) -> (String, Bool) {
        guard text.count > limit else { return (text, false) }
        let end = text.index(text.startIndex, offsetBy: limit)
        let head = text[..<end]
        if let lastBreak = head.lastIndex(where: { $0 == "\n" || $0 == "\r\n" }), head.distance(from: head.startIndex, to: lastBreak) > limit / 2 {
            return (String(head[..<lastBreak]), true)
        }
        return (String(head), true)
    }

    /// The part of a selection (UTF-16) that `used`, a prefix of its text, covers: what a rewrite of
    /// it may replace, so text the model never saw is never deleted.
    static func usedRange(_ range: NSRange, used: String) -> NSRange {
        NSRange(location: range.location, length: min(range.length, used.utf16.count))
    }

    /// The same for a selection of bytes (the large-file view).
    static func usedBytes(_ range: Range<Int>, used: String) -> Range<Int> {
        range.lowerBound..<min(range.upperBound, range.lowerBound + used.utf8.count)
    }

    /// An Explain or Summarise answer with its Markdown (**bold**, `code`) shown as styled text, line
    /// breaks kept. Links are kept only to web pages: an answer can be steered by the text it's about,
    /// so a link to a file, an app or a script mustn't become clickable.
    #if canImport(Darwin)
    static func styledAnswer(_ answer: String) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var styled = try? AttributedString(markdown: answer, options: options) else { return nil }
        for run in styled.runs {
            if let link = run.link, !isWebLink(link) { styled[run.range].link = nil }
        }
        return styled
    }
    #endif

    /// A link to a web page (http or https), the only kind an answer may have.
    static func isWebLink(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    /// The regular expression in the model's answer: the first non-empty line, without the backticks,
    /// quotes, slashes or "Regex:" label small models sometimes add anyway.
    static func cleanedPattern(_ answer: String) -> String {
        var lines = answer.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        lines.removeAll { $0.isEmpty || $0.hasPrefix("```") }
        guard var pattern = lines.first else { return "" }
        for label in ["regex:", "regular expression:", "pattern:"] where pattern.lowercased().hasPrefix(label) {
            pattern = String(pattern.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        for (open, close) in [("`", "`"), ("\"", "\""), ("'", "'"), ("/", "/")] {
            if pattern.count >= 2, pattern.hasPrefix(open), pattern.hasSuffix(close) {
                pattern = String(pattern.dropFirst().dropLast())
            }
        }
        return pattern
    }

    /// A rewrite without the code fence or quotes a model sometimes wraps it in.
    static func cleanedRewrite(_ answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            text = String(text.dropFirst(3).dropLast(3))
            if let firstBreak = text.firstIndex(of: "\n"), !text[..<firstBreak].contains(" ") { // A language name after the fence.
                text = String(text[text.index(after: firstBreak)...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
