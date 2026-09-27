import SwiftUI

struct SearchCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandMenu("Search") { SearchMenuItems(context: context) }
    }
}

private struct SearchMenuItems: View {
    let context: WorkspaceCommandContext
    var body: some View {
        Group {
            Button("Find…") { context.find(.showFindInterface) }.keyboardShortcut("f")
                .disabled(!context.hasDocument)
            Button("Find Next") { context.find(.nextMatch) }.keyboardShortcut("g")
                .disabled(!context.hasDocument)
            Button("Find Previous") { context.find(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!context.hasDocument)
            Button("Replace…") { context.find(.showReplaceInterface) }.keyboardShortcut("h")
                .disabled(!context.hasDocument)
            Divider()
            Button("Find in Files…") {
                context.search.show(.files)
            }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Find All in Current Document") { context.search.findAll() }.disabled(!context.hasDocument || !context.search.canSearch)
            Divider()
            Button("Go to Line…") {
                context.search.showGoToLine()
            }.keyboardShortcut("l").disabled(!context.hasDocument)
        }
    }
}
