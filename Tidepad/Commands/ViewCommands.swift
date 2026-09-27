import SwiftUI

struct ViewCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandGroup(replacing: .toolbar) { ViewMenuItems(context: context) }
    }
}

private struct ViewMenuItems: View {
    let context: WorkspaceCommandContext
    var body: some View {
        Group {
            // "=" is the unshifted +/= key, so ⌘= zooms in without needing Shift on US/UK layouts.
            Button("Zoom In") { context.zoom(by: 1) }.keyboardShortcut("=")
            Button("Zoom Out") { context.zoom(by: -1) }.keyboardShortcut("-")
            Button("Reset Zoom", action: context.resetZoom).keyboardShortcut("0")
            Divider()
            Toggle("Show Line Numbers", isOn: binding(\.showLineNumbers))
            Toggle("Show Status Bar", isOn: binding(\.showStatusBar))
            Toggle("Show Toolbar", isOn: binding(\.showToolbar))
            Divider()
            Toggle("Word Wrap", isOn: binding(\.wordWrap))
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<EditorPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { context.preferences[keyPath: keyPath] }, set: {
            context.preferences[keyPath: keyPath] = $0
            context.applyDisplayOptions()
        })
    }
}
