import AppKit
import Observation

/// The folder open in the window, if any: what the sidebar shows, where Find in Files looks, and
/// where a terminal opens. Tidepad remembers recent folders and reopens the last one at launch.
@MainActor @Observable final class ProjectFolder {
    /// The open folder, with symbolic links resolved so paths match what FSEvents reports.
    private(set) var url: URL?
    private(set) var rules = FolderIgnoreRules()
    /// Shown when a folder opens; with no folder it offers Open Folder and recent folders.
    var showSidebar = false
    /// Show build output, `.git` and `.gitignore`d files too.
    var showIgnored = false { didSet { if showIgnored != oldValue { generation += 1 } } }
    private(set) var recentFolders: [URL] = []
    /// Changes whenever the tree must be rebuilt: another folder, or the ignore setting changed.
    private(set) var generation = 0
    /// Called after a folder opens, e.g. to point Find in Files at it.
    @ObservationIgnored var didOpen: ((URL) -> Void)?
    /// Called after the folder closes.
    @ObservationIgnored var didClose: (() -> Void)?
    /// Creates a file (false) or folder (true) where the tree's selection is; set by the file tree.
    @ObservationIgnored var createItem: ((_ directory: Bool) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    private static let recentKey = "TidepadRecentFolders", lastKey = "TidepadLastFolder"
    private static let maximumRecent = 10

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentFolders = (defaults.stringArray(forKey: Self.recentKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    var name: String { url?.lastPathComponent ?? "" }

    func open(_ folder: URL) {
        let resolved = folder.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            recentFolders.removeAll { $0.path == resolved.path }
            saveRecent()
            return
        }
        url = resolved
        rules = FolderIgnoreRules(root: resolved)
        showSidebar = true
        generation += 1
        recentFolders.removeAll { $0.path == resolved.path }
        recentFolders.insert(resolved, at: 0)
        recentFolders = Array(recentFolders.prefix(Self.maximumRecent))
        saveRecent()
        defaults.set(resolved.path, forKey: Self.lastKey)
        didOpen?(resolved)
    }

    func close() {
        url = nil
        showSidebar = false
        generation += 1
        defaults.removeObject(forKey: Self.lastKey)
        didClose?()
    }

    /// Re-reads `.gitignore` after it changes.
    func reloadRules() {
        guard let url else { return }
        rules = FolderIgnoreRules(root: url)
        generation += 1
    }

    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to open in Tidepad."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        open(folder)
    }

    /// Reopens the folder that was open when Tidepad last quit.
    func restoreLastFolder() {
        guard let path = defaults.string(forKey: Self.lastKey) else { return }
        open(URL(fileURLWithPath: path))
    }

    func clearRecentFolders() {
        recentFolders = []
        saveRecent()
    }

    private func saveRecent() { defaults.set(recentFolders.map(\.path), forKey: Self.recentKey) }

    /// Whether a URL is a folder to open as a project (not a file, and not a package such as an app).
    nonisolated static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}
