import SwiftUI

struct SettingsCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {}
        CommandMenu("Settings") { SettingsMenuItems(context: context) }
    }
}

private struct SettingsMenuItems: View {
    let context: WorkspaceCommandContext
    var body: some View {
        Group {
            Button("Preferences…") {
                context.placeholder("Tidepad Preferences", detail: "A full preferences window is planned. For now, use the Settings menu to choose a theme, editor font, or tab size. Tidepad remembers these choices, and the open tabs with any unsaved text, between launches.")
            }.keyboardShortcut(",")
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
