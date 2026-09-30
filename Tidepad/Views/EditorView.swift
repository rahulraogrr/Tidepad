import SwiftUI

struct EditorView: View {
    let document: EditorDocument
    let sessions: EditorSessionStore
    let preferences: EditorPreferences
    var body: some View {
        if let file = document.largeFile {
            // Files too large for NSTextView (see LargeTextView).
            LargeFileHostView(view: sessions.largeView(for: document, file: file, options: preferences.displayOptions),
                              file: file, options: preferences.displayOptions).id(document.id)
        } else {
            AppKitTextView(session: sessions.session(for: document), language: document.syntaxLanguage, options: preferences.displayOptions).id(document.id)
        }
    }
}
