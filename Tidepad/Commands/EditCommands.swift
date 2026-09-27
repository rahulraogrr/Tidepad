import SwiftUI

struct EditCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        // AppKit supplies undo/redo, clipboard, Delete and Select All through the responder chain.
        CommandGroup(after: .textEditing) { EditMenuItems(context: context) }
    }
}

private struct EditMenuItems: View {
    let context: WorkspaceCommandContext
    var body: some View {
        Group {
            Button("Duplicate Current Line") { context.run(.duplicateLines) }
                .keyboardShortcut("d")
            Button("Delete Current Line") { context.run(.deleteLines) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Move Line Up") { context.run(.moveLinesUp) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Move Line Down") { context.run(.moveLinesDown) }
                .keyboardShortcut("]", modifiers: [.command, .option])
        }.disabled(!context.hasDocument)
    }
}
