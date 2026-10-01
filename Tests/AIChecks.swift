import Foundation

/// The on-device AI's prompts (Foundation only; the model itself is tried by hand, since it needs
/// Apple Intelligence): cutting long text to fit, and cleaning up the model's answers.
@main struct AIChecks {
    static func main() {
        // Cutting to fit: at the last line break past halfway, or at the limit.
        let lines = (0..<2_000).map { "line \($0) of the log" }.joined(separator: "\n")
        let (clipped, cut) = AIPrompt.clip(lines)
        precondition(cut && clipped.count <= AIPrompt.inputLimit && lines.hasPrefix(clipped) && !clipped.hasSuffix("\n")
                     && lines.dropFirst(clipped.count).hasPrefix("\n"), "Cut at a line break")
        let oneLine = String(repeating: "x", count: 20_000)
        precondition(AIPrompt.clip(oneLine).0.count == AIPrompt.inputLimit, "Cut a long line at the limit")
        precondition(AIPrompt.clip("short") == ("short", false), "Short text kept")
        precondition(AIPrompt.clip(String(repeating: "తెలుగు ", count: 3_000)).0.count == AIPrompt.inputLimit, "Characters, not bytes")

        // Prompts carry the text and the language, and say what to do.
        let explain = AIPrompt(.explain, text: "SELECT 1", language: "SQL")
        precondition(explain.prompt.contains("SELECT 1") && explain.prompt.contains("(SQL)") && !explain.clipped)
        precondition(AIPrompt(.summarise, text: lines).clipped, "Summarise notes when text was cut")
        for style in AIRewriteStyle.allCases {
            let rewrite = AIPrompt(.rewrite(style), text: "teh text")
            precondition(rewrite.prompt == "teh text" && rewrite.instructions.contains("only the rewritten text"), "Rewrite \(style)")
        }
        precondition(AIPrompt(.regex("email addresses"), text: "").prompt.hasSuffix("email addresses"))

        // A rewrite of text cut to fit replaces only the part the model was given, never the rest.
        let long = (0..<1_500).map { "😀 línea \($0) తెలుగు\r\n" }.joined()
        let cutRewrite = AIPrompt(.rewrite(.grammar), text: long)
        precondition(cutRewrite.clipped && long.hasPrefix(cutRewrite.usedText) && cutRewrite.prompt == cutRewrite.usedText, "The text given")
        let selection = NSRange(location: 40, length: (long as NSString).length)
        let used = AIPrompt.usedRange(selection, used: cutRewrite.usedText)
        precondition(used.location == 40 && used.length == cutRewrite.usedText.utf16.count && used.length < selection.length
                     && (long as NSString).substring(with: NSRange(location: 0, length: used.length)) == cutRewrite.usedText,
                     "Replace covers the UTF-16 of the text given")
        let bytes = AIPrompt.usedBytes(100..<(100 + long.utf8.count), used: cutRewrite.usedText)
        precondition(bytes == 100..<(100 + cutRewrite.usedText.utf8.count), "And its bytes in a large file")
        let whole = AIPrompt(.rewrite(.shorter), text: "short text")
        precondition(!whole.clipped && AIPrompt.usedRange(NSRange(location: 3, length: 10), used: whole.usedText) == NSRange(location: 3, length: 10)
                     && AIPrompt.usedBytes(3..<13, used: whole.usedText) == 3..<13, "All of a short selection")
        precondition(AIRequest.rewrite(.shorter).title == "Make Shorter" && AIRequest.regex("x").title == "Write Regular Expression")

        // Links in answers: web pages stay clickable; anything else (files, apps, scripts) is plain text.
        for (link, web) in [("https://developer.apple.com", true), ("HTTP://example.com", true), ("file:///etc/passwd", false),
                            ("javascript:alert(1)", false), ("x-apple.systempreferences:x", false), ("tidepad://open", false)] {
            precondition(AIPrompt.isWebLink(URL(string: link)!) == web, "Web link? \(link)")
        }
        #if canImport(Darwin)
        let linked = AIPrompt.styledAnswer("See [docs](https://developer.apple.com), [this](file:///etc/passwd), [run](javascript:alert(1)) and [app](x-apple.systempreferences:x). **Bold** `code`")!
        let links = linked.runs.compactMap(\.link)
        precondition(links == [URL(string: "https://developer.apple.com")!], "Only web links: \(links)")
        precondition(String(linked.characters) == "See docs, this, run and app. Bold code", "Text kept: \(String(linked.characters))")
        #endif

        // Answers cleaned up.
        let patterns: [(String, String)] = [
            ("\\d{3}-\\d{4}", "\\d{3}-\\d{4}"),
            ("`\\bstatus=5\\d\\d\\b`", "\\bstatus=5\\d\\d\\b"),
            ("```regex\n^ERROR.*$\n```", "^ERROR.*$"),
            ("Regex: [A-Z]+", "[A-Z]+"),
            ("\"foo|bar\"", "foo|bar"),
            ("/^\\s+$/", "^\\s+$"),
            ("  \n  a+b  \nExplanation: …", "a+b"),
            ("", "")
        ]
        for (answer, expected) in patterns {
            precondition(AIPrompt.cleanedPattern(answer) == expected, "Pattern from \(answer.debugDescription): \(AIPrompt.cleanedPattern(answer).debugDescription)")
        }
        precondition(AIPrompt.cleanedRewrite("```\nFixed text.\n```") == "Fixed text.")
        precondition(AIPrompt.cleanedRewrite("```markdown\n- one\n- two\n```") == "- one\n- two")
        precondition(AIPrompt.cleanedRewrite("  The text.\n") == "The text.")
        print("AI checks passed: only web links in answers, text cut to fit (at line breaks, by characters), Replace limited to the text given, prompts for Explain, Summarise, Rewrite and regular expressions, answers cleaned up.")
    }
}
