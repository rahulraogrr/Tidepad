import SwiftUI
import AppKit

struct EditorToolbar: View {
    let manager: DocumentManager
    let sessions: EditorSessionStore
    let find: () -> Void

    var body: some View {
        let _ = EditorDiagnostics.view("EditorToolbar")
        HStack(spacing: TidepadMetrics.toolbarSpacing) {
            tool("New (⌘N)", icon: "doc.badge.plus", tint: TidepadTheme.toolbarNew, action: manager.newDocument)
            tool("Open… (⌘O)", icon: "folder.fill", tint: TidepadTheme.toolbarOpen, action: manager.open)
            tool("Save (⌘S)", icon: "square.and.arrow.down.fill", tint: TidepadTheme.toolbarSave) {
                if let document = manager.selectedDocument { manager.save(document) }
            }.disabled(manager.selectedDocument == nil)
            separator
            tool("Undo (⌘Z)", icon: "arrow.uturn.backward", tint: TidepadTheme.toolbarUndo) { editor?.undoManager?.undo() }
            tool("Redo (⇧⌘Z)", icon: "arrow.uturn.forward", tint: TidepadTheme.toolbarUndo) { editor?.undoManager?.redo() }
            separator
            tool("Cut (⌘X)", icon: "scissors", tint: TidepadTheme.toolbarClipboard) { editor?.cut(nil) }
            tool("Copy (⌘C)", icon: "doc.on.doc", tint: TidepadTheme.toolbarClipboard) { editor?.copy(nil) }
            tool("Paste (⌘V)", icon: "doc.on.clipboard", tint: TidepadTheme.toolbarClipboard) { editor?.paste(nil) }
            separator
            tool("Find… (⌘F)", icon: "magnifyingglass", tint: TidepadTheme.toolbarFind, action: find)
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
    private func tool(_ title: String, icon: String, tint: NSColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: TidepadMetrics.toolbarIconSize, weight: .regular))
                .foregroundStyle(Color(nsColor: tint))
                .frame(width: TidepadMetrics.toolbarButtonSize, height: TidepadMetrics.toolbarButtonSize)
        }.buttonStyle(CompactChromeButtonStyle()).help(title).accessibilityLabel(title)
    }
}
