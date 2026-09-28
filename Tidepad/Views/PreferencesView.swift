import SwiftUI
import AppKit

/// Tidepad ▸ Settings… (⌘,): the standard Mac settings window, a SwiftUI `Settings` scene with a tab
/// for each group. Changes apply at once and are remembered (EditorPreferences), just like the same
/// commands in the View and Settings menus.
struct PreferencesView: View {
    let context: WorkspaceCommandContext

    var body: some View {
        TabView {
            GeneralPreferencesPane(context: context)
                .tabItem { Label("General", systemImage: "gearshape") }
            EditorPreferencesPane(context: context)
                .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
        }
        .frame(width: 480)
    }
}

extension WorkspaceCommandContext {
    /// A setting as a binding for a control: changing it saves it and updates every open editor.
    func preference<Value>(_ keyPath: ReferenceWritableKeyPath<EditorPreferences, Value>) -> Binding<Value> {
        Binding(get: { self.preferences[keyPath: keyPath] }, set: { value in
            self.preferences[keyPath: keyPath] = value
            self.applyDisplayOptions()
        })
    }
}

private struct GeneralPreferencesPane: View {
    let context: WorkspaceCommandContext

    var body: some View {
        Form {
            Picker("Appearance:", selection: Binding(get: { context.preferences.appearance }, set: { context.setAppearance($0) })) {
                ForEach(EditorAppearance.allCases, id: \.self) { appearance in Text(appearance.rawValue).tag(appearance) }
            }
            .pickerStyle(.radioGroup)
            LabeledContent("Show:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Toolbar", isOn: context.preference(\.showToolbar))
                    Toggle("Status bar", isOn: context.preference(\.showStatusBar))
                }
            }
        }
        .padding(20)
    }
}

private struct EditorPreferencesPane: View {
    let context: WorkspaceCommandContext
    private var preferences: EditorPreferences { context.preferences }

    var body: some View {
        let font = EditorFontProvider.font(configuration: preferences.displayOptions.font)
        Form {
            LabeledContent("Font:") {
                HStack {
                    Text("\(font.displayName ?? font.fontName) \(Int(preferences.fontSize)) pt")
                        .font(Font(font as CTFont))
                        .lineLimit(1)
                    Button("Choose…") { context.showEditorFont() }
                }
            }
            // Steppers with hidden labels, so every row's label lines up in the form's label column.
            LabeledContent("Font size:") {
                HStack {
                    Text("\(Int(preferences.fontSize)) pt").monospacedDigit()
                    Stepper("Font size", value: context.preference(\.fontSize), in: 8...48, step: 1).labelsHidden()
                }
            }
            LabeledContent("Tab width:") {
                HStack {
                    Text(preferences.tabSize == 1 ? "1 space" : "\(preferences.tabSize) spaces").monospacedDigit()
                    Stepper("Tab width", value: context.preference(\.tabSize), in: 1...16).labelsHidden()
                }
            }
            LabeledContent("Show:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Line numbers", isOn: context.preference(\.showLineNumbers))
                    Toggle("Wrap long lines", isOn: context.preference(\.wordWrap))
                }
            }
            LabeledContent("") {
                Button("Restore Defaults", action: restoreDefaults)
            }
        }
        .padding(20)
    }

    private func restoreDefaults() {
        preferences.fontName = nil
        preferences.fontSize = TidepadMetrics.editorFontSize
        preferences.tabSize = 4
        preferences.showLineNumbers = true
        preferences.wordWrap = false
        context.applyDisplayOptions()
    }
}
