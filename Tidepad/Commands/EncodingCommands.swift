import SwiftUI

struct EncodingCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandMenu("Encoding") { EncodingMenuItems(context: context) }
    }
}

/// The Encoding menu, as in Notepad++. The ticked encoding is the one the document is saved in;
/// choosing another converts it (the text stays the same). Reopen with Encoding reads the file again
/// in another encoding, for a file that was guessed wrongly. Line Endings converts every line break.
private struct EncodingMenuItems: View {
    let context: WorkspaceCommandContext

    var body: some View {
        Group {
            ForEach(TextEncodingChoice.common) { choice in convertItem(choice) }
            Menu("Other Encodings") {
                ForEach(TextEncodingChoice.others) { choice in convertItem(choice) }
            }
            Divider()
            Menu("Reopen with Encoding") {
                ForEach(TextEncodingChoice.reopenable) { choice in
                    Button(choice.name) { context.reopen(with: choice) }
                }
            }
            .disabled(context.document?.fileURL == nil)
            Divider()
            Menu("Line Endings") {
                ForEach(LineEnding.allCases, id: \.self) { ending in
                    Toggle(ending.statusName, isOn: Binding(get: { context.document?.lineEnding == ending },
                                                            set: { _ in context.convertLineEndings(to: ending) }))
                }
            }
        }
        .disabled(!context.hasDocument || context.document?.isLarge == true) // Not yet for large files: they'd be re-encoded whole.
    }

    private func convertItem(_ choice: TextEncodingChoice) -> some View {
        Toggle(choice.name, isOn: Binding(get: { context.document?.encodingChoice == choice },
                                          set: { _ in context.convertEncoding(to: choice) }))
    }
}
