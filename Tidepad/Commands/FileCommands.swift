import SwiftUI
import AppKit

struct FileCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New", action: context.documents.newDocument).keyboardShortcut("n")
            Button("Open…", action: context.documents.open).keyboardShortcut("o")
            Button("Open Folder…", action: context.project.chooseAndOpen).keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) { FileMenuItems(context: context) }
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { NSApp.runPageLayout(nil) }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Print…") { context.printDocument() }.keyboardShortcut("p").disabled(!context.hasDocument)
        }
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
            Button("Close Folder", action: context.project.close).disabled(context.project.url == nil)
            Divider()
            Menu("Recent Files") {
                ForEach(context.documents.recentFiles, id: \.self) { url in
                    Button(url.lastPathComponent) { context.documents.openInBackground([url]) }.help(url.path)
                }
                Divider()
                Button("Clear Recent Files", action: context.documents.clearRecentFiles)
                    .disabled(context.documents.recentFiles.isEmpty)
            }
            Menu("Recent Folders") {
                ForEach(context.project.recentFolders, id: \.self) { url in
                    Button(url.lastPathComponent) { context.project.open(url) }.help(url.path)
                }
                Divider()
                Button("Clear Recent Folders", action: context.project.clearRecentFolders)
                    .disabled(context.project.recentFolders.isEmpty)
            }
        }
    }
}
