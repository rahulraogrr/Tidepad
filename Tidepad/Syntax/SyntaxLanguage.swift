import Foundation

enum SyntaxLanguage: String, Sendable, CaseIterable {
    case plain, swift, java, json, xml, sql, javascript, typescript, html, css, yaml, markdown

    init(fileExtension: String?) {
        switch fileExtension?.lowercased() {
        case "swift": self = .swift
        case "java": self = .java
        case "json": self = .json
        case "xml": self = .xml
        case "sql": self = .sql
        case "js", "mjs", "cjs": self = .javascript
        case "ts", "tsx": self = .typescript
        case "html", "htm": self = .html
        case "css": self = .css
        case "yaml", "yml": self = .yaml
        case "md", "markdown": self = .markdown
        default: self = .plain
        }
    }

    var displayName: String {
        switch self {
        case .plain: return "Normal text"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .json, .xml, .sql, .html, .css, .yaml: return rawValue.uppercased()
        default: return rawValue.capitalized
        }
    }

    var isMarkup: Bool { self == .xml || self == .html }
    var hasSlashComments: Bool { [.swift, .java, .javascript, .typescript].contains(self) }
    var hasBlockComments: Bool { hasSlashComments || self == .sql || self == .css }
    var keywords: Set<String> {
        let words: String
        switch self {
        case .swift:
            words = "actor as associatedtype async await break case catch class continue convenience default defer deinit do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect init inout internal is isolated lazy let mutating nonisolated open operator override private protocol public repeat required rethrows return self Self set some static struct subscript super switch throws throw try typealias var weak where while"
        case .java:
            words = "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for if implements import instanceof int interface long native new package private protected public record return short static strictfp super switch synchronized this throw throws transient try var void volatile while yield"
        case .javascript, .typescript:
            words = "abstract any as async await boolean break case catch class const constructor continue debugger declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface keyof let module namespace never new number of private protected public readonly return set static string super switch symbol this throw try type typeof unknown var void while with yield"
        case .sql:
            words = "select from where insert into update delete create alter drop table index view join inner outer left right full on as and or not in is like between exists distinct group by having order asc desc limit offset union all values set primary key foreign references constraint default case when then else end begin commit rollback with recursive count sum avg min max"
        case .css:
            words = "important inherit initial unset auto none block inline flex grid relative absolute fixed solid dotted dashed px em rem vh vw rgb rgba var calc media supports keyframes from to"
        default: words = ""
        }
        return Set(words.split(separator: " ").map(String.init))
    }
}

enum SyntaxKind: Sendable { case keyword, string, number, comment, literal, punctuation, tag, heading }
struct SyntaxToken: Sendable, Equatable {
    var range: NSRange
    let kind: SyntaxKind
}

struct SyntaxPolicy: Sendable {
    var isEnabled = true
    var maximumUTF16Length = 1_000_000
    var debounceNanoseconds: UInt64 = 90_000_000
    var maximumPaintLength = 80_000
}

/// Analysis tiers are based on the Release lexer matrix. Native editing and undo remain enabled.
enum EditorPerformanceMode {
    case normal, medium, large
    init(utf16Length: Int) {
        self = utf16Length <= 1_000_000 ? .normal : utf16Length < 10_000_000 ? .medium : .large
    }
    var permitsSyntax: Bool { self == .normal }
}
