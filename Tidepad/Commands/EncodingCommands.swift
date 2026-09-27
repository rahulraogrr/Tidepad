import SwiftUI

struct EncodingCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        CommandMenu("Encoding") { EncodingMenuItems(context: context) }
    }
}

private struct EncodingMenuItems: View {
    let context: WorkspaceCommandContext
    var body: some View {
        Group {
            encoding("UTF-8", selected: context.document?.encoding == .utf8 && context.document?.hasByteOrderMark == false)
            encoding("UTF-8 with BOM", selected: context.document?.encoding == .utf8 && context.document?.hasByteOrderMark == true)
            encoding("UTF-16 LE", selected: context.document?.encoding == .utf16LittleEndian || context.document?.encoding == .utf16)
            encoding("UTF-16 BE", selected: context.document?.encoding == .utf16BigEndian)
            encoding("ASCII", selected: context.document?.encoding == .ascii)
            Divider()
            Button("Convert to UTF-8") {}.disabled(true)
            Button("Convert to UTF-8 BOM") {}.disabled(true)
        }
    }
    private func encoding(_ title: String, selected: Bool) -> some View {
        Toggle(title, isOn: .constant(selected)).disabled(true)
            .help("Current encoding is informational. Encoding conversion is not implemented.")
    }
}
