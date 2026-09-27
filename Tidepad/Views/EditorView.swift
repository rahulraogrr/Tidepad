import SwiftUI

struct EditorView: View {
    let document: EditorDocument
    let sessions: EditorSessionStore
    let preferences: EditorPreferences
    var body: some View {
        AppKitTextView(session: sessions.session(for: document), language: document.syntaxLanguage, options: preferences.displayOptions).id(document.id)
    }
}
