import Foundation

/// The project sidebar's folder model: ignore rules and folder listings (Foundation only).
@main struct FolderChecks {
    static func main() throws {
        // Ignore rules: defaults, .gitignore names, globs, folder-only and rooted patterns.
        let rules = FolderIgnoreRules(gitignore: """
            # build output
            *.class
            logs/
            /dist
            config/local.yml
            **/generated
            !keep.class

            """)
        let ignored: [(String, Bool)] = [
            (".git", true), ("node_modules", true), ("target", true), ("src/.DS_Store", false),
            ("Main.class", false), ("src/deep/App.class", false), ("logs", true), ("app/logs", true),
            ("dist", true), ("config/local.yml", false), ("a/b/generated", true)
        ]
        for (path, isDirectory) in ignored {
            precondition(rules.isIgnored(relativePath: path, isDirectory: isDirectory), "Should be ignored: \(path)")
        }
        let shown: [(String, Bool)] = [
            ("src", true), (".gitignore", false), ("Main.java", false), ("logs", false), ("app/dist", true),
            ("other/config/local.yml", false), ("pom.xml", false), ("classes", true)
        ]
        for (path, isDirectory) in shown {
            precondition(!rules.isIgnored(relativePath: path, isDirectory: isDirectory), "Should be shown: \(path)")
        }

        // Listing a real folder: folders first, Finder order, ignored items hidden unless asked.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tidepad-folder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for folder in ["src/main/java", "target/classes", ".git", "docs", "Zeta"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["pom.xml", "README.md", ".gitignore", "file10.txt", "file2.txt", "App.class", "src/main/java/App.java"] {
            fm.createFile(atPath: root.appendingPathComponent(file).path, contents: Data())
        }
        try "*.class\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked-docs"), withDestinationURL: root.appendingPathComponent("docs"))
        let projectRules = FolderIgnoreRules(root: root)
        let names = FolderListing.entries(of: root, root: root, rules: projectRules).map(\.name)
        precondition(names == ["docs", "linked-docs", "src", "Zeta", ".gitignore", "file2.txt", "file10.txt", "pom.xml", "README.md"],
                     "Listing: \(names)")
        let everything = FolderListing.entries(of: root, root: root, rules: projectRules, showIgnored: true).map(\.name)
        precondition(everything.contains(".git") && everything.contains("target") && everything.contains("App.class"), "Show ignored: \(everything)")
        let nested = FolderListing.entries(of: root.appendingPathComponent("src/main"), root: root, rules: projectRules)
        precondition(nested.map(\.name) == ["java"] && nested[0].isDirectory)
        precondition(FolderListing.relativePath(of: root.appendingPathComponent("src/main/java"), root: root) == "src/main/java")
        precondition(FolderListing.relativePath(of: root, root: root) == "")
        precondition(FolderListing.entries(of: root.appendingPathComponent("missing"), root: root, rules: projectRules).isEmpty)
        print("Folder checks passed: ignore rules (defaults, .gitignore globs, folders, rooted paths), listing order, symlinked folders, showing ignored items.")
    }
}
