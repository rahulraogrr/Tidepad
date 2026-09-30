import AppKit
import SwiftUI
import Observation

/// Tools ▸ On-Device AI and the editors' right-click menus: Explain, Summarise, Rewrite and Write
/// Regular Expression, answered by Apple's on-device model (OnDeviceModel) in a small floating panel,
/// like the Search panel. The answer appears as it's written and can be stopped. A rewrite is shown
/// first and goes in only with Replace, as one undoable edit, if the text hasn't changed meanwhile.
@MainActor @Observable final class AIController {
    private(set) var request: AIRequest?
    private(set) var output = ""
    private(set) var note = ""
    private(set) var busy = false
    private(set) var failed = false
    /// Regular expression: what to find, in words, and the checked expression from the answer.
    var regexDescription = ""
    private(set) var pattern: String?

    @ObservationIgnored weak var context: WorkspaceCommandContext?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private let menuTarget = AIMenuTarget()

    /// Where a rewrite goes: the text it came from, as it was.
    private enum Source {
        case text(document: UUID, revision: UInt64, range: NSRange)
        case bytes(document: UUID, revision: Int, range: Range<Int>)
    }
    @ObservationIgnored private var source: Source?

    init(context: WorkspaceCommandContext) {
        self.context = context
        menuTarget.controller = self
    }

    var isSupported: Bool { OnDeviceModel.isSupported }
    var isRegex: Bool { if case .regex = request { return true }; return false }
    var isRewrite: Bool { if case .rewrite = request { return true }; return false }
    var canReplace: Bool { isRewrite && !busy && !failed && !output.isEmpty && source != nil }

    // MARK: Commands

    func run(_ request: AIRequest) {
        guard isSupported else { NSSound.beep(); return }
        if case .regex(let description) = request, description.trimmingCharacters(in: .whitespaces).isEmpty {
            // Ask what to find first.
            stop()
            self.request = request
            output = ""; note = ""; failed = false; pattern = nil
            showPanel()
            return
        }
        let input: (text: String, source: Source?, language: String?)
        if case .regex = request {
            input = ("", nil, nil)
        } else {
            guard let found = selectedText(for: request) else { return }
            input = found
        }
        stop()
        self.request = request
        source = input.source
        output = ""
        pattern = nil
        failed = false
        showPanel()
        if let reason = OnDeviceModel.unavailableReason() { fail(reason); return }
        let prompt = AIPrompt(request, text: input.text, language: input.language)
        note = prompt.clipped ? "Only the first \(AIPrompt.inputLimit.formatted()) characters were used." : ""
        busy = true
        task = Task { [weak self] in
            do {
                for try await text in OnDeviceModel.answer(prompt) {
                    guard let self, !Task.isCancelled else { return }
                    self.output = text
                }
                if !Task.isCancelled { self?.finished() }
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(OnDeviceModel.message(for: error))
            }
        }
    }

    /// Write Regular Expression, from the panel's field.
    func writeRegex() { run(.regex(regexDescription)) }

    func stop() {
        task?.cancel()
        task = nil
        if busy { busy = false; note = "Stopped." }
    }

    private func finished() {
        busy = false
        task = nil
        switch request {
        case .regex:
            let candidate = AIPrompt.cleanedPattern(output)
            output = candidate
            do {
                _ = try SearchEngine(SearchQuery(text: candidate, mode: .regex))
                pattern = candidate
            } catch {
                failed = true
                note = "That isn't a valid regular expression. Try describing it another way."
            }
        case .rewrite:
            output = AIPrompt.cleanedRewrite(output)
        default: break
        }
    }

    private func fail(_ message: String) {
        busy = false
        failed = true
        task = nil
        note = message
    }

    /// Puts the rewrite in place of the text it came from, as one undoable edit.
    func replace() {
        guard canReplace, let context, let document = context.document, let source else { return }
        switch source {
        case .text(let id, let revision, let range):
            guard let session = context.session, id == document.id, document.revision == revision else { return changed() }
            let text = document.lineEnding.applied(to: output)
            let edit = TextEdit(range: range, text: text, selection: NSRange(location: range.location, length: (text as NSString).length),
                                actionName: request?.title ?? "Rewrite")
            guard session.apply(edit) else { return changed() }
        case .bytes(let id, let revision, let range):
            guard let view = context.largeView, id == document.id, view.buffer.revision == revision else { return changed() }
            let bytes = Array(view.lineBreakText(output).utf8)
            view.replace(matches: [(range: range, bytes: bytes)], in: range, select: range.lowerBound..<(range.lowerBound + bytes.count),
                         action: request?.title ?? "Rewrite")
        }
        self.source = nil
        note = "Replaced. Undo (⌘Z) puts the original back."
    }

    private func changed() {
        source = nil
        note = "The text changed since this was written, so it wasn't replaced. Select it and try again."
    }

    /// Puts the regular expression in the Find panel.
    func useInFind() {
        guard let pattern, let search = context?.search else { return }
        var query = search.query
        query.text = pattern
        query.mode = .regex
        search.query = query
        search.show(.find)
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    // MARK: The text asked about

    /// The selection, or, with nothing selected, the caret's line (Explain), the whole document or the
    /// lines on screen in a large file (Summarise). Rewrite needs a selection.
    private func selectedText(for request: AIRequest) -> (text: String, source: Source?, language: String?)? {
        guard let context, let document = context.document else { NSSound.beep(); return nil }
        let language = document.syntaxLanguage == .plain ? nil : document.syntaxLanguage.displayName
        if let session = context.session {
            let text = session.textView.string as NSString
            var range = session.textView.selectedRange()
            if range.length == 0 {
                switch request {
                case .explain: range = text.lineRange(for: range)
                case .summarise: range = NSRange(location: 0, length: text.length)
                default: return needsSelection()
                }
            }
            return (text.substring(with: range), .text(document: document.id, revision: document.revision, range: range), language)
        }
        if let view = context.largeView {
            let buffer = view.buffer
            var range = view.selectedBytes
            if range.isEmpty {
                switch request {
                case .explain: range = buffer.lineRange(buffer.line(containing: range.lowerBound))
                case .summarise: range = view.visibleBytes
                default: return needsSelection()
                }
            }
            // Never read more than the model could take, however big the selection.
            let read = range.lowerBound..<min(range.upperBound, range.lowerBound + AIPrompt.inputLimit * 4)
            return (buffer.text(in: read), .bytes(document: document.id, revision: buffer.revision, range: range), language)
        }
        return nil
    }

    private func needsSelection() -> (text: String, source: Source?, language: String?)? {
        stop()
        request = nil
        output = ""
        failed = true
        note = "Select the text to rewrite first."
        showPanel()
        return nil
    }

    // MARK: Menus

    /// The right-click menu's On-Device AI submenu (empty on macOS without the framework).
    func menuItems() -> [NSMenuItem] {
        guard isSupported else { return [] }
        let submenu = NSMenu(title: "On-Device AI")
        func item(_ title: String, _ request: AIRequest) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(AIMenuTarget.runRequest(_:)), keyEquivalent: "")
            item.target = menuTarget
            item.representedObject = AIMenuTarget.Box(request)
            return item
        }
        submenu.addItem(item("Explain", .explain))
        submenu.addItem(item("Summarise", .summarise))
        let rewrite = NSMenuItem(title: "Rewrite", action: nil, keyEquivalent: "")
        rewrite.submenu = NSMenu(title: "Rewrite")
        for style in AIRewriteStyle.allCases { rewrite.submenu?.addItem(item(style.rawValue, .rewrite(style))) }
        submenu.addItem(rewrite)
        submenu.addItem(.separator())
        submenu.addItem(item("Write Regular Expression…", .regex("")))
        let root = NSMenuItem(title: "On-Device AI", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return [root]
    }

    // MARK: Panel

    private func showPanel() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "On-Device AI"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.level = .floating
            panel.contentMinSize = NSSize(width: 420, height: 260)
            panel.contentView = NSHostingView(rootView: AIPanelView(controller: self))
            panel.center()
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        stop()
        panel?.orderOut(nil)
        context?.window?.makeKeyAndOrderFront(nil)
    }
}

/// The target of the right-click menu's items (NSMenuItem needs an Objective-C object).
@MainActor final class AIMenuTarget: NSObject {
    final class Box: NSObject {
        let request: AIRequest
        init(_ request: AIRequest) { self.request = request }
    }
    weak var controller: AIController?
    @objc func runRequest(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? Box else { return }
        controller?.run(box.request)
    }
}

/// The panel: what to find (for a regular expression), the answer as it's written, and its actions.
private struct AIPanelView: View {
    @Bindable var controller: AIController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(controller.request?.title ?? "On-Device AI").font(.headline)
                Spacer()
                Text("Apple Intelligence · on this Mac").font(.caption).foregroundStyle(.secondary)
            }
            if controller.isRegex {
                HStack {
                    TextField("Describe what to find, e.g. lines with an email address", text: $controller.regexDescription)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { controller.writeRegex() }
                    Button("Write") { controller.writeRegex() }
                        .disabled(controller.busy || controller.regexDescription.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ScrollView {
                answer
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack(spacing: 8) {
                if controller.busy { ProgressView().controlSize(.small) }
                Text(controller.busy ? "Writing…" : controller.note)
                    .font(.callout)
                    .foregroundStyle(controller.failed ? Color.red : Color.secondary)
                    .lineLimit(2)
                Spacer()
                if controller.busy {
                    Button("Stop") { controller.stop() }
                } else {
                    Button("Copy") { controller.copy() }.disabled(controller.output.isEmpty)
                    if controller.isRewrite {
                        Button("Replace") { controller.replace() }.disabled(!controller.canReplace).keyboardShortcut(.defaultAction)
                    }
                    if controller.isRegex {
                        Button("Use in Find") { controller.useInFind() }.disabled(controller.pattern == nil).keyboardShortcut(.defaultAction)
                    }
                }
                Button("Close") { controller.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 420, minHeight: 260)
    }

    @ViewBuilder private var answer: some View {
        switch controller.request {
        case .explain?, .summarise?:
            // Small models often use **bold** and `code`: shown as such, keeping line breaks.
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            if let styled = try? AttributedString(markdown: controller.output, options: options) {
                Text(styled)
            } else {
                Text(controller.output)
            }
        default:
            Text(controller.output).font(.system(.body, design: .monospaced))
        }
    }
}
