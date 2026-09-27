import AppKit
import UniformTypeIdentifiers

/// One file or folder in the sidebar. A folder's children are read the first time it's expanded.
@MainActor final class FileNode: NSObject {
    let url: URL
    let name: String
    let isDirectory: Bool
    weak var parent: FileNode?
    /// nil until the folder has been read.
    var children: [FileNode]?

    init(url: URL, name: String, isDirectory: Bool, parent: FileNode?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.parent = parent
    }
}

/// The project sidebar's file tree: Apple's NSOutlineView, the control Finder and Xcode use for
/// trees. Folders are read only when expanded, so large projects open instantly, and FSEvents keeps
/// the folders that have been read up to date.
@MainActor final class FileTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let scrollView = NSScrollView()
    let outlineView = NSOutlineView()
    private let project: ProjectFolder
    private let openFile: @MainActor (URL) -> Void
    private var root: FileNode?
    private var watcher: FolderWatcher?
    private var generation = -1
    private var revealedURL: URL?
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("FileTreeCell")

    init(project: ProjectFolder, openFile: @escaping @MainActor (URL) -> Void) {
        self.project = project
        self.openFile = openFile
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .small
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.autoresizesOutlineColumn = false
        outlineView.backgroundColor = TidepadTheme.sidebarBackground
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked)
        outlineView.setAccessibilityLabel("Project files")
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        project.createItem = { [weak self] directory in self?.createInSelection(directory: directory) }
    }

    /// New File / New Folder from the sidebar header: inside the selected folder, beside the selected
    /// file, or at the top of the project, as in VS Code.
    func createInSelection(directory: Bool) {
        guard let root else { return }
        let selected = node(atRow: outlineView.selectedRow)
        let folder = selected.map { $0.isDirectory ? $0 : ($0.parent ?? root) } ?? root
        create(in: folder, directory: directory)
    }

    /// Brings the tree up to date with the project and highlights the file being edited.
    func update(selectedFile: URL?) {
        if generation != project.generation {
            generation = project.generation
            rebuild()
        }
        let selected = selectedFile?.standardizedFileURL.resolvingSymlinksInPath()
        if selected != revealedURL {
            revealedURL = selected
            reveal(selected)
        }
    }

    private func rebuild() {
        watcher = nil
        root = project.url.map { FileNode(url: $0, name: $0.lastPathComponent, isDirectory: true, parent: nil) }
        outlineView.reloadData()
        if let url = project.url {
            watcher = FolderWatcher(folder: url) { [weak self] paths in
                MainActor.assumeIsolated { self?.foldersChanged(paths) }
            }
        }
        revealedURL = nil
    }

    // MARK: Data source

    private func children(of item: Any?) -> [FileNode] {
        guard let node = (item as? FileNode) ?? root else { return [] }
        if node.children == nil { node.children = read(node) }
        return node.children ?? []
    }

    private func read(_ node: FileNode) -> [FileNode] {
        guard let rootURL = project.url else { return [] }
        return FolderListing.entries(of: node.url, root: rootURL, rules: project.rules, showIgnored: project.showIgnored).map {
            FileNode(url: $0.url, name: $0.name, isDirectory: $0.isDirectory, parent: node)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory == true }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView ?? makeCell()
        cell.textField?.stringValue = node.name
        cell.imageView?.image = icon(for: node)
        cell.toolTip = node.url.path
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellIdentifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        for view in [image, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// The same icons Finder shows.
    private func icon(for node: FileNode) -> NSImage {
        let image = node.isDirectory ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(forFile: node.url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    // MARK: Clicks

    /// A click opens a file, or opens or closes a folder, as in VS Code.
    @objc private func clicked() {
        guard let node = node(atRow: outlineView.clickedRow) else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) } else { outlineView.expandItem(node) }
        } else {
            openFile(node.url)
        }
    }

    private func node(atRow row: Int) -> FileNode? {
        row >= 0 ? outlineView.item(atRow: row) as? FileNode : nil
    }

    /// Expands the folders down to `url` and selects it, without opening anything.
    func reveal(_ url: URL?) {
        guard let url, let root else { outlineView.deselectAll(nil); return }
        let relative = FolderListing.relativePath(of: url, root: root.url)
        guard url.path.hasPrefix(root.url.path + "/"), !relative.isEmpty else { outlineView.deselectAll(nil); return }
        var node = root
        for component in relative.split(separator: "/") {
            guard let child = children(of: node).first(where: { $0.name == String(component) }) else {
                outlineView.deselectAll(nil); return // Hidden by the ignore rules.
            }
            if child.isDirectory { outlineView.expandItem(child) }
            node = child
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: Live updates

    private func foldersChanged(_ paths: [String]) {
        guard let root else { return }
        for path in Set(paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }) {
            // FSEvents reports folders; a changed .gitignore shows up as a change to the project folder.
            if path == root.url.path, project.rules != FolderIgnoreRules(root: root.url) {
                project.reloadRules()
                return // The generation changed: the next update rebuilds the tree.
            }
            if let node = loadedFolder(at: path, from: root) { refresh(node) }
        }
    }

    /// The folder at `path`, if it's been read.
    private func loadedFolder(at path: String, from root: FileNode) -> FileNode? {
        if path == root.url.path { return root }
        guard path.hasPrefix(root.url.path + "/") else { return nil }
        var node = root
        for component in path.dropFirst(root.url.path.count + 1).split(separator: "/") {
            guard let child = node.children?.first(where: { $0.name == String(component) }), child.children != nil else { return nil }
            node = child
        }
        return node
    }

    /// Re-reads a folder, keeping the existing nodes (and so their expanded state) for items still there.
    private func refresh(_ node: FileNode) {
        guard let old = node.children else { return }
        let existing = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        node.children = read(node).map { fresh in
            if let kept = existing[fresh.name], kept.isDirectory == fresh.isDirectory { return kept }
            return fresh
        }
        outlineView.reloadItem(node === root ? nil : node, reloadChildren: true)
        if let revealedURL, outlineView.selectedRow < 0 { reveal(revealedURL) }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let root else { return }
        let node = self.node(atRow: outlineView.clickedRow) ?? root
        let folder = node.isDirectory ? node : (node.parent ?? root)
        menu.addItem(ClosureMenuItem("New File…") { [weak self] in self?.create(in: folder, directory: false) })
        menu.addItem(ClosureMenuItem("New Folder…") { [weak self] in self?.create(in: folder, directory: true) })
        if node !== root {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Rename…") { [weak self] in self?.rename(node) })
            menu.addItem(ClosureMenuItem("Move to Trash") { [weak self] in self?.trash(node) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) })
        menu.addItem(ClosureMenuItem("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        })
        menu.addItem(ClosureMenuItem("Open in Terminal") { Self.openTerminal(at: folder.url) })
    }

    /// Opens Terminal.app in a folder.
    static func openTerminal(at folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    private func create(in folder: FileNode, directory: Bool) {
        guard let name = askName(directory ? "New Folder" : "New File", confirm: "Create", initial: "") else { return }
        let url = folder.url.appendingPathComponent(name)
        do {
            guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path]) }
            if directory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch { show(error); return }
        if folder.children != nil { refresh(folder) }
        if folder !== root { outlineView.expandItem(folder) }
        if !directory { openFile(url) }
    }

    private func rename(_ node: FileNode) {
        guard let name = askName("Rename “\(node.name)”", confirm: "Rename", initial: node.name), name != node.name else { return }
        do { try FileManager.default.moveItem(at: node.url, to: node.url.deletingLastPathComponent().appendingPathComponent(name)) }
        catch { show(error); return }
        if let parent = node.parent { refresh(parent) }
    }

    /// Moves to the Trash, as Finder does, so it can be put back.
    private func trash(_ node: FileNode) {
        do { try FileManager.default.trashItem(at: node.url, resultingItemURL: nil) } catch { show(error); return }
        if let parent = node.parent { refresh(parent) }
    }

    private func askName(_ title: String, confirm: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            if !name.isEmpty { show(CocoaError(.fileWriteInvalidFileName)) }
            return nil
        }
        return name
    }

    private func show(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}

/// A menu item that runs a closure.
@MainActor final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("Not archivable") }

    @objc private func run() { handler() }
}
