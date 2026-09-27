import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What the project sidebar hides: folders that build tools and version control create in most
/// projects, plus whatever the project's own `.gitignore` lists. Supports the common subset of
/// `.gitignore`: names and globs (`*.class`), a trailing `/` for folders only, and a leading or
/// inner `/` to match a path from the project root. Negations (`!`) are skipped.
struct FolderIgnoreRules: Equatable, Sendable {
    static let defaultNames: Set<String> = [
        ".git", ".svn", ".hg", ".DS_Store", "node_modules", "target", "build", ".build", ".gradle",
        ".idea", "DerivedData", "__pycache__", ".next"
    ]

    private struct Pattern: Equatable, Sendable {
        let glob: String
        let directoryOnly: Bool
        /// Matches the path from the project root rather than just the name.
        let rooted: Bool
    }
    private var patterns: [Pattern] = []

    init(gitignore: String? = nil) {
        for rawLine in (gitignore ?? "").split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            let directoryOnly = line.hasSuffix("/")
            if directoryOnly { line.removeLast() }
            if line.hasPrefix("**/") { line.removeFirst(3) }
            let rooted = line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            guard !line.isEmpty else { continue }
            patterns.append(Pattern(glob: line, directoryOnly: directoryOnly, rooted: rooted))
        }
    }

    /// Reads the `.gitignore` at the project root, if there is one.
    init(root: URL) {
        self.init(gitignore: try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8))
    }

    /// `relativePath` is the item's path from the project root, e.g. `src/main/App.java`.
    func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        if Self.defaultNames.contains(name) { return true }
        for pattern in patterns where isDirectory || !pattern.directoryOnly {
            let subject = pattern.rooted ? relativePath : name
            if fnmatch(pattern.glob, subject, pattern.rooted ? FNM_PATHNAME : 0) == 0 { return true }
        }
        return false
    }
}

struct FolderEntry: Equatable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
}

enum FolderListing {
    /// The items in `directory`, folders first and then files, each in Finder's order. Hidden files
    /// such as `.gitignore` are shown; ignored items are left out unless `showIgnored` is set.
    static func entries(of directory: URL, root: URL, rules: FolderIgnoreRules, showIgnored: Bool = false) -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        let base = relativePath(of: directory, root: root)
        var entries: [FolderEntry] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            var isDirectory = values?.isDirectory == true
            if values?.isSymbolicLink == true {
                // A link to a folder is shown as that folder.
                isDirectory = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            let name = url.lastPathComponent
            let relative = base.isEmpty ? name : base + "/" + name
            if !showIgnored && rules.isIgnored(relativePath: relative, isDirectory: isDirectory) { continue }
            entries.append(FolderEntry(url: url, name: name, isDirectory: isDirectory))
        }
        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The path of `url` from `root`, without a leading slash; empty for the root itself.
    static func relativePath(of url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path, rootPath = root.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
