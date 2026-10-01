import SwiftUI

struct LanguageCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandMenu("Language") { LanguageMenuItems(context: context) }
    }
}

/// The Language menu, as in Notepad++: Normal Text, then the languages under a submenu per first letter
/// (worked out from their names, so a new language files itself), then Use File Extension.
private struct LanguageMenuItems: View {
    let context: WorkspaceCommandContext

    /// Languages grouped by first letter, in alphabetical order.
    private var groups: [(letter: String, languages: [SyntaxLanguage])] {
        let languages = SyntaxLanguage.allCases.filter { $0 != .plain }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let letters = Dictionary(grouping: languages) { String($0.displayName.prefix(1)).uppercased() }
        return letters.keys.sorted().map { ($0, letters[$0] ?? []) }
    }

    var body: some View {
        Group {
            language(.plain, title: "None (Normal Text)")
            Divider()
            ForEach(groups, id: \.letter) { group in
                Menu(group.letter) {
                    ForEach(group.languages, id: \.self) { value in language(value, title: value.displayName) }
                }
                .disabled(!context.hasDocument)
            }
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
