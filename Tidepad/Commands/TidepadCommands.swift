import SwiftUI
import AppKit

struct TidepadCommands: Commands {
    let context: WorkspaceCommandContext
    var body: some Commands {
        FileCommands(context: context)
        EditCommands(context: context)
        SearchCommands(context: context)
        ViewCommands(context: context)
        EncodingCommands(context: context)
        LanguageCommands(context: context)
        SettingsCommands(context: context)
        ToolsCommands(context: context)
        CommandGroup(replacing: .appVisibility) {
            // Cmd+H belongs to Replace; keep Hide available with an unambiguous alternate shortcut.
            Button("Hide Tidepad") { NSApp.hide(nil) }.keyboardShortcut("h", modifiers: [.command, .control])
            Button("Hide Others") { NSApp.hideOtherApplications(nil) }.keyboardShortcut("h", modifiers: [.command, .option])
            Button("Show All") { NSApp.unhideAllApplications(nil) }
        }
        CommandGroup(replacing: .help) {
            // Tidepad Help is an Apple Help Book (Tidepad/Tidepad.help), shown in macOS's Help Viewer;
            // the Help menu's search field searches it too.
            Button("Tidepad Help") { NSApp.showHelp(nil) }.keyboardShortcut("?", modifiers: .command)
            Button("Keyboard Shortcuts") { TidepadHelp.open("shortcuts") }
        }
    }
}

/// Opens pages of Tidepad Help by their anchors (`<a name="…">` in the pages, found through the
/// book's search index; see Scripts/build-help-index.sh).
enum TidepadHelp {
    static var book: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String ?? "" }
    @MainActor static func open(_ anchor: String) { NSHelpManager.shared.openHelpAnchor(anchor, inBook: book) }
}
