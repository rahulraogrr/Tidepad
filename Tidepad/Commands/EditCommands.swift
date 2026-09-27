import SwiftUI

struct EditCommands: Commands {
    var body: some Commands {
        // AppKit supplies undo/redo, clipboard, Delete and Select All through the responder chain.
        CommandGroup(after: .textEditing) {
            Button("Duplicate Current Line") {}.disabled(true)
            Button("Delete Current Line") {}.disabled(true)
            Button("Move Line Up") {}.disabled(true)
            Button("Move Line Down") {}.disabled(true)
        }
    }
}
