import SwiftUI

struct LanguageCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandMenu("Language") { LanguageMenuItems(context: context) }
    }
}

private struct LanguageMenuItems: View {
    let context: WorkspaceCommandContext
    private let languages: [SyntaxLanguage] = [.css, .html, .java, .javascript, .json, .markdown, .sql, .swift, .typescript, .xml, .yaml]
    var body: some View {
        Group {
            language(.plain, title: "Normal Text")
            Divider()
            Button("C / C++") {}.disabled(true)
            ForEach(languages, id: \.self) { value in language(value, title: value.displayName) }
            Divider()
            Button("Use File Extension") { context.setLanguage(nil) }
                .disabled(!context.hasDocument || context.document?.languageOverride == nil)
        }
    }
    private func language(_ value: SyntaxLanguage, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { context.document?.syntaxLanguage == value }, set: { _ in context.setLanguage(value) }))
            .disabled(!context.hasDocument)
    }
}
