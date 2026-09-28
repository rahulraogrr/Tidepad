import SwiftUI
import AppKit

/// The toolbar, laid out as Notepad++'s: files, clipboard, undo, find, zoom. Each button runs the same
/// command as its menu item.
struct EditorToolbar: View {
    let context: WorkspaceCommandContext
    private var manager: DocumentManager { context.documents }
    private var sessions: EditorSessionStore { context.sessions }

    var body: some View {
        let _ = EditorDiagnostics.view("EditorToolbar")
        let noDocument = manager.selectedDocument == nil
        HStack(spacing: TidepadMetrics.toolbarSpacing) {
            tool("New (⌘N)", icon: "doc.badge.plus", tint: TidepadTheme.toolbarNew, action: manager.newDocument)
            tool("Open… (⌘O)", icon: "doc.fill", tint: TidepadTheme.toolbarOpen, action: manager.open)
            tool("Open Folder… (⇧⌘O)", icon: "folder.fill", tint: TidepadTheme.toolbarOpen) { context.project.chooseAndOpen() }
            tool("Save (⌘S)", icon: "square.and.arrow.down.fill", tint: TidepadTheme.toolbarSave) { context.save() }
                .disabled(noDocument)
            tool("Save All", icon: "square.and.arrow.down.on.square.fill", tint: TidepadTheme.toolbarSave, action: manager.saveAll)
                .disabled(manager.documents.isEmpty)
            tool("Close Tab (⌘W)", icon: "xmark.square", tint: TidepadTheme.toolbarClose) { context.closeTab() }
                .disabled(noDocument)
            tool("Close All", icon: "xmark.square.fill", tint: TidepadTheme.toolbarClose) { manager.closeAll() }
                .disabled(manager.documents.isEmpty)
            tool("Print… (⌘P)", icon: "printer.fill", tint: TidepadTheme.toolbarClipboard) { context.printDocument() }
                .disabled(noDocument)
            separator
            tool("Cut (⌘X)", icon: "scissors", tint: TidepadTheme.toolbarClipboard) { editor?.cut(nil) }
            tool("Copy (⌘C)", icon: "doc.on.doc", tint: TidepadTheme.toolbarClipboard) { editor?.copy(nil) }
            tool("Paste (⌘V)", icon: "doc.on.clipboard", tint: TidepadTheme.toolbarClipboard) { editor?.paste(nil) }
            separator
            tool("Undo (⌘Z)", icon: "arrow.uturn.backward", tint: TidepadTheme.toolbarUndo) { editor?.undoManager?.undo() }
            tool("Redo (⇧⌘Z)", icon: "arrow.uturn.forward", tint: TidepadTheme.toolbarUndo) { editor?.undoManager?.redo() }
            separator
            tool("Find… (⌘F)", icon: "magnifyingglass", tint: TidepadTheme.toolbarFind) { context.find(.showFindInterface) }
                .disabled(noDocument)
            tool("Replace… (⌘H)", icon: "arrow.triangle.2.circlepath", tint: TidepadTheme.toolbarFind) { context.find(.showReplaceInterface) }
                .disabled(noDocument)
            separator
            tool("Zoom In (⌘=)", icon: "plus.magnifyingglass", tint: TidepadTheme.toolbarFind) { context.zoom(by: 1) }
            tool("Zoom Out (⌘−)", icon: "minus.magnifyingglass", tint: TidepadTheme.toolbarFind) { context.zoom(by: -1) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TidepadMetrics.toolbarHorizontalPadding).frame(height: TidepadMetrics.toolbarHeight)
        .background(Color(nsColor: TidepadTheme.toolbarBackground))
        .overlay(alignment: .bottom) { ChromeSeparator() }
    }

    private var editor: NSTextView? {
        manager.selectedDocument.map { sessions.session(for: $0).textView }
    }
    private var separator: some View {
        ChromeSeparator(vertical: true).frame(height: TidepadMetrics.toolbarSeparatorHeight)
            .padding(.horizontal, TidepadMetrics.toolbarGroupPadding)
    }
    private func tool(_ title: String, icon: String, tint: NSColor, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: TidepadMetrics.toolbarIconSize, weight: .regular))
                .foregroundStyle(Color(nsColor: tint))
                .frame(width: TidepadMetrics.toolbarButtonSize, height: TidepadMetrics.toolbarButtonSize)
        }.buttonStyle(CompactChromeButtonStyle()).help(title).accessibilityLabel(title)
    }
}
