import AppKit

@MainActor enum NativeMenuCoordinator {
    /// SwiftUI owns app commands; AppKit arranges menus and supplies the native full-screen item.
    private static let viewDelegate = NativeViewMenuDelegate()

    static func arrange() {
        guard let main = NSApp.mainMenu else { return }
        let names = ["Tidepad", "File", "Edit", "Search", "View", "Encoding", "Language", "Settings", "Tools", "Window", "Help"]
        let sorted = names.compactMap { name in main.items.first { $0.title == name || $0.submenu?.title == name } }
        guard sorted.count == names.count else { return }
        for (index, item) in sorted.enumerated() where main.index(of: item) != index {
            main.removeItem(item)
            main.insertItem(item, at: index)
        }
        if let view = main.items.first(where: { $0.title == "View" })?.submenu {
            if view.delegate !== viewDelegate {
                viewDelegate.original = view.delegate
                view.delegate = viewDelegate
            }
            viewDelegate.ensureFullScreen(in: view)
        }
        // Remove empty-group separators emitted by the standard CommandGroup placements.
        for top in main.items {
            guard let menu = top.submenu else { continue }
            var previousWasSeparator = true
            for item in menu.items {
                if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) }
                else { previousWasSeparator = item.isSeparatorItem }
            }
            if menu.items.last?.isSeparatorItem == true, let last = menu.items.last { menu.removeItem(last) }
        }
        if let edit = main.items.first(where: { $0.title == "Edit" })?.submenu,
           let select = edit.items.first(where: { $0.action == #selector(NSText.selectAll(_:)) }) {
            let index = edit.index(of: select)
            if index > 0 && !edit.items[index - 1].isSeparatorItem { edit.insertItem(.separator(), at: index) }
        }
        if let file = main.items.first(where: { $0.title == "File" })?.submenu {
            // Keep native window closing available without stealing Cmd+W from Close Tab.
            for item in file.items where item.action == #selector(NSWindow.performClose(_:)) {
                item.title = "Close Window"
                item.keyEquivalent = "w"
                item.keyEquivalentModifierMask = [.command, .shift]
            }
        }
    }
}

/// SwiftUI rebuilds menu contents when state changes. Restore the native item after each refresh.
@MainActor private final class NativeViewMenuDelegate: NSObject, NSMenuDelegate {
    weak var original: (any NSMenuDelegate)?

    func menuNeedsUpdate(_ menu: NSMenu) {
        original?.menuNeedsUpdate?(menu)
        ensureFullScreen(in: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        original?.menuWillOpen?(menu)
        ensureFullScreen(in: menu)
    }

    func menuDidClose(_ menu: NSMenu) { original?.menuDidClose?(menu) }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) { original?.menu?(menu, willHighlight: item) }

    /// Marks Tidepad's own full-screen item.
    private static let fullScreenTag = 0x46_53

    func ensureFullScreen(in menu: NSMenu) {
        let ours = menu.items.first { $0.tag == Self.fullScreenTag }
        // Recent macOS versions add their own full-screen item (fn/🌐-F); then Tidepad's steps aside.
        let system = menu.items.contains { item in
            item.tag != Self.fullScreenTag && (item.action == #selector(NSWindow.toggleFullScreen(_:)) || item.title.hasSuffix("Full Screen"))
        }
        if system {
            if let ours { menu.removeItem(ours) }
            return
        }
        guard ours == nil else { return }
        let item = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.control, .command]
        item.tag = Self.fullScreenTag
        item.target = nil
        if menu.items.last?.isSeparatorItem != true { menu.addItem(.separator()) }
        menu.addItem(item)
    }
}
