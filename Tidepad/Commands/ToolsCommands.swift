import SwiftUI

struct ToolsCommands: Commands {
    var body: some Commands {
        CommandMenu("Tools") {
            Button("Format JSON") {}.disabled(true)
            Button("Format XML") {}.disabled(true)
            Divider()
            Menu("Convert Case") {
                Button("UPPERCASE") {}.disabled(true)
                Button("lowercase") {}.disabled(true)
                Button("Title Case") {}.disabled(true)
            }
            Divider()
            Button("Sort Lines Ascending") {}.disabled(true)
            Button("Sort Lines Descending") {}.disabled(true)
            Button("Remove Duplicate Lines") {}.disabled(true)
        }
    }
}
