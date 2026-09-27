import SwiftUI

struct FileCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New", action: context.documents.newDocument).keyboardShortcut("n")
            Button("Open…", action: context.documents.open).keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) { FileMenuItems(context: context) }
    }
}

private struct FileMenuItems: View {
    let context: WorkspaceCommandContext
    var body: some View {
        Group {
            Button("Save") { context.save() }.keyboardShortcut("s").disabled(!context.hasDocument)
            Button("Save As…") { context.save(asNew: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!context.hasDocument)
            Button("Save All", action: context.documents.saveAll).disabled(context.documents.documents.isEmpty)
            Divider()
            Button("Close Tab", action: context.closeTab).keyboardShortcut("w").disabled(!context.hasDocument)
            Button("Close All") { context.documents.closeAll() }.disabled(context.documents.documents.isEmpty)
            Button("Close Other Tabs") { context.documents.closeAll(except: context.document?.id) }
                .disabled(context.documents.documents.count < 2 || !context.hasDocument)
            Divider()
            Menu("Recent Files") {
                ForEach(context.documents.recentFiles, id: \.self) { url in
                    Button(url.lastPathComponent) { context.documents.openInBackground([url]) }.help(url.path)
                }
                Divider()
                Button("Clear Recent Files", action: context.documents.clearRecentFiles)
                    .disabled(context.documents.recentFiles.isEmpty)
            }
        }
    }
}
