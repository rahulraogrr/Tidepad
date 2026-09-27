import SwiftUI
import AppKit

struct AppKitTextView: NSViewRepresentable {
    let session: EditorSession
    let language: SyntaxLanguage
    let options: EditorDisplayOptions

    func makeNSView(context: Context) -> NSScrollView {
        session.applyDisplayOptions(options)
        let view = session.scrollView
        DispatchQueue.main.async { view.window?.makeFirstResponder(session.textView) }
        return view
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        session.setLanguage(language)
        session.applyDisplayOptions(options)
    }
}
