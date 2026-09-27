import SwiftUI
import AppKit

struct TidepadCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        FileCommands(context: context)
        EditCommands()
        SearchCommands(context: context)
        ViewCommands(context: context)
        EncodingCommands(context: context)
        LanguageCommands(context: context)
        SettingsCommands(context: context)
        ToolsCommands()
        CommandGroup(replacing: .appVisibility) {
            // Cmd+H belongs to Replace; keep Hide available with an unambiguous alternate shortcut.
            Button("Hide Tidepad") { NSApp.hide(nil) }.keyboardShortcut("h", modifiers: [.command, .control])
            Button("Hide Others") { NSApp.hideOtherApplications(nil) }.keyboardShortcut("h", modifiers: [.command, .option])
            Button("Show All") { NSApp.unhideAllApplications(nil) }
        }
        CommandGroup(replacing: .help) {
            Button("Tidepad Help") {
                context.placeholder("Tidepad Help", detail: "Use File to open and save documents, Search for Find, Replace, and recursive Find in Files, View for display options, and Language to override syntax coloring. Greyed-out commands are planned but not implemented.")
            }
            Button("Keyboard Shortcuts") {
                context.placeholder("Keyboard Shortcuts", detail: "⌘N  New\n⌘O  Open\n⌘S  Save\n⇧⌘S  Save As\n⌘W  Close Tab\n⌘Z / ⇧⌘Z  Undo / Redo\n⌘X / ⌘C / ⌘V  Cut / Copy / Paste\n⌘A  Select All\n⌘F  Find\n⌘G / ⇧⌘G  Find Next / Previous\n⌘H  Replace\n⇧⌘F  Find in Files\n⌘L  Go to Line\n⌘+ / ⌘− / ⌘0  Zoom\n⌘,  Preferences\n⌃⌘H  Hide Tidepad")
            }
        }
    }
}
