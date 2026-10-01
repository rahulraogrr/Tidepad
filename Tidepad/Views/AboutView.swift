import SwiftUI
import AppKit

/// Tidepad ▸ About Tidepad: the icon beside the name and version, when this copy was built, what
/// Tidepad is, the Mac it's running on (useful in a bug report), the home page and the copyright, with
/// Close and Copy and Close (copies the version and system details). A small SwiftUI window, because
/// the standard About panel shows such text in a bordered scroll box and NSAlert can't be laid out
/// like this. The version and copyright come from Info.plist; the build date is the app's own.
struct AboutView: View {
    static let windowID = "about"
    private let info = Bundle.main.infoDictionary ?? [:]
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .trailing, spacing: 20) {
            HStack(alignment: .top, spacing: 22) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TidePad \(version)").font(.title.bold())
                        Text(buildLine).foregroundStyle(.secondary)
                    }
                    Text("A fast, native Mac text editor in the spirit of Notepad++, built only with Apple’s own frameworks. It opens files of hundreds of megabytes and has a built-in terminal.")
                    Text("On-device AI explains, summarises and rewrites text and writes regular expressions, with Apple Intelligence running on your Mac. Nothing you write leaves it.")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(systemLine)
                        Text("On-device AI: \(aiState)")
                    }
                    .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Home: [github.com/rahulraogrr/Tidepad](https://github.com/rahulraogrr/Tidepad)")
                        Text(value("NSHumanReadableCopyright"))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Button("Close") { dismissWindow(id: Self.windowID) }
                    .keyboardShortcut(.cancelAction)
                Button("Copy and Close") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(details, forType: .string)
                    dismissWindow(id: Self.windowID)
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .frame(width: 580)
        .background(AboutWindowStyle())
    }

    private var version: String { AppDetails.version }
    private var buildLine: String { AppDetails.buildLine }
    private var systemLine: String { AppDetails.systemLine }
    private var aiState: String { AppDetails.aiState }
    /// What Copy and Close copies, for a bug report.
    private var details: String { AppDetails.summary }
    private func value(_ key: String) -> String { info[key] as? String ?? "" }
}

/// Makes the About window like a Mac About window: it can't be minimised (or resized: see the scene).
private struct AboutWindowStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.styleMask.remove(.miniaturizable) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Tidepad ▸ About Tidepad opens the window above.
struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About TidePad") { openWindow(id: AboutView.windowID) }
    }
}
