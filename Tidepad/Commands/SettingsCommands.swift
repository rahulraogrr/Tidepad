import SwiftUI

struct SettingsCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandMenu("Settings") { SettingsMenuItems(context: context) }
    }
}

private struct SettingsMenuItems: View {
    let context: WorkspaceCommandContext
    var body: some View {
        Group {
            // Opens the same window as Tidepad ▸ Settings… (⌘,), for Notepad++ users who look here.
            SettingsLink { Text("Preferences…") }
            Menu("Style / Theme") {
                ForEach(EditorAppearance.allCases, id: \.self) { appearance in
                    Toggle(appearance.rawValue, isOn: Binding(get: { context.preferences.appearance == appearance }, set: { _ in context.setAppearance(appearance) }))
                }
            }
            Button("Editor Font…", action: context.showEditorFont)
            Menu("Tab Size") {
                ForEach([2, 4, 8], id: \.self) { width in
                    Toggle("\(width)", isOn: Binding(get: { context.preferences.tabSize == width }, set: { _ in
                        context.preferences.tabSize = width
                        context.applyDisplayOptions()
                    }))
                }
            }
        }
    }
}
