import Foundation

enum SearchMode: String, CaseIterable, Sendable { case normal = "Normal", extended = "Extended", regex = "Regular expression" }
struct SearchQuery: Equatable, Sendable {
    var text = ""
    var mode: SearchMode = .normal
    var matchCase = false
    var wholeWord = false
    var wrap = true
}

/// Search backends own traversal. A future chunked provider implements these operations
/// without promising a materialized whole-document String to the controller.
protocol SearchTextSource: Sendable {
    var utf16Length: Int { get }
    func nextMatch(using engine: SearchEngine, from offset: Int, backwards: Bool,
                   excluding: NSRange?, cancelled: () -> Bool) -> SearchMatch?
    func enumerateMatches(using engine: SearchEngine, range: NSRange?, cancelled: () -> Bool,
                          visit: (NSRange, NSTextCheckingResult?) -> Bool)
}
struct SearchSnapshot: SearchTextSource, Sendable {
    let text: String
    let revision: UInt64
    var utf16Length: Int { (text as NSString).length }
    func nextMatch(using engine: SearchEngine, from offset: Int, backwards: Bool,
                   excluding: NSRange?, cancelled: () -> Bool) -> SearchMatch? {
        engine.nextSnapshot(self, from: offset, backwards: backwards, excluding: excluding, cancelled: cancelled)
    }
    func enumerateMatches(using engine: SearchEngine, range: NSRange?, cancelled: () -> Bool,
                          visit: (NSRange, NSTextCheckingResult?) -> Bool) {
        engine.enumerateSnapshot(self, range: range, cancelled: cancelled, visit: visit)
    }
}
struct SearchMatch: Sendable, Equatable { let range: NSRange }
struct SearchResult: Identifiable, Sendable {
    let id = UUID()
    let documentID: UUID?
    let url: URL?
    let name: String
    let revision: UInt64?
    let range: NSRange
    let line: Int
    let column: Int
    let preview: String
    let fileDate: Date?
    let fileSize: Int?
}
struct SearchHistory {
    private(set) var finds: [String] = []
    private(set) var replacements: [String] = []
    private(set) var directories: [String] = []
    private(set) var filters: [String] = []
    mutating func record(find: String, replacement: String, directory: String, filter: String) {
        Self.add(find, to: &finds); Self.add(replacement, to: &replacements)
        Self.add(directory, to: &directories); Self.add(filter, to: &filters)
    }
    private static func add(_ value: String, to list: inout [String]) {
        guard !value.isEmpty else { return }; list.removeAll { $0 == value }; list.insert(value, at: 0)
        if list.count > 20 { list.removeLast(list.count - 20) }
    }
}

enum SearchFailure: LocalizedError {
    case empty, invalidEscape, tooManyReplacements
    var errorDescription: String? {
        switch self {
        case .empty: return "Enter text to find."
        case .invalidEscape: return "Extended mode supports \\n, \\r, \\t, \\0 and \\\\."
        case .tooManyReplacements: return "More than 100,000 replacements. Narrow the search or selection. No text was changed."
        }
    }
}

struct SearchTiming {
    #if DEBUG
    private let start = ContinuousClock.now
    private let name: String
    init(_ name: String) { self.name = name }
    func finish() { print("SEARCH \(name): \(start.duration(to: .now))") }
    #else
    init(_ name: String) {}
    func finish() {}
    #endif
}
