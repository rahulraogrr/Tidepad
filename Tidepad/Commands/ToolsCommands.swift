import SwiftUI

struct ToolsCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandMenu("Tools") { ToolsMenuItems(context: context) }
    }
}

/// Sort and duplicate removal work on the selected lines, or the whole document when nothing is
/// selected. Formatting works on the selection or the whole document; Format SQL follows the style of
/// the "SQL Formatter" VS Code extension (sql-formatter-plus). Case needs a selection.
private struct ToolsMenuItems: View {
    let context: WorkspaceCommandContext
    var body: some View {
        Group {
            documentTools
            Divider()
            Toggle("Terminal", isOn: Binding(get: { context.terminal.isVisible },
                                             set: { $0 ? context.terminal.show() : context.terminal.hide() }))
                .keyboardShortcut("`", modifiers: .control)
            Button("New Terminal") { context.terminal.newTerminal() }
        }
    }

    private var documentTools: some View {
        Group {
            Menu("Format") {
                Button("JSON") { context.run(.formatJSON) }.keyboardShortcut("j", modifiers: [.control, .option])
                Button("XML") { context.run(.formatXML) }.keyboardShortcut("x", modifiers: [.control, .option])
                Button("SQL") { context.run(.formatSQL) }.keyboardShortcut("s", modifiers: [.control, .option])
            }
            Menu("Convert Case") {
                Button("UPPERCASE") { context.run(.convertCase(.upper)) }
                Button("lowercase") { context.run(.convertCase(.lower)) }
                Button("Title Case") { context.run(.convertCase(.title)) }
            }
            Divider()
            Button("Sort Lines Ascending") { context.run(.sortLines(ascending: true)) }
            Button("Sort Lines Descending") { context.run(.sortLines(ascending: false)) }
            Button("Remove Duplicate Lines") { context.run(.removeDuplicateLines) }
        }.disabled(!context.hasDocument)
    }
}
