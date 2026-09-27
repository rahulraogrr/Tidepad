import AppKit

/// Shows a change Claude Code proposes, as a unified diff with a few lines of context, with Accept and
/// Reject. A separate, non-modal window, so the terminal stays usable: the same change can be answered
/// there, and Claude Code then closes this window. Closing it counts as Reject.
@MainActor final class DiffReviewWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var decided: ((Bool) -> Void)?

    init(tabName: String, path: String, old: String, new: String, decided: @escaping (Bool) -> Void) {
        self.decided = decided
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Review Change: \(URL(fileURLWithPath: path).lastPathComponent)"
        window.subtitle = tabName
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("TidepadDiffReview")

        let lines = LineDiff.lines(old: old, new: new)
        let summary = LineDiff.summary(lines)
        let font = NSFont(name: "Menlo", size: TidepadMetrics.editorFontSize)
            ?? .monospacedSystemFont(ofSize: TidepadMetrics.editorFontSize, weight: .regular)

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = TidepadTheme.editorBackground
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(Self.render(lines, font: font))
        textView.setAccessibilityLabel("Proposed change")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        textView.autoresizingMask = [.width]

        let info = NSTextField(labelWithString: "Claude Code proposes changes to \(path)  ·  +\(summary.added) −\(summary.removed) lines")
        info.lineBreakMode = .byTruncatingMiddle
        info.textColor = .secondaryLabelColor
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let reject = NSButton(title: "Reject", target: self, action: #selector(rejectClicked))
        reject.keyEquivalent = "\u{1B}"
        let accept = NSButton(title: "Accept", target: self, action: #selector(acceptClicked))
        accept.keyEquivalent = "\r"
        let bar = NSStackView(views: [info, reject, accept])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        bar.setHuggingPriority(.defaultHigh, for: .vertical)
        let stack = NSStackView(views: [scrollView, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func show() {
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window as a rejection (Claude Code closing the tab, or another change replacing it).
    func dismiss() { finish(false) }

    @objc private func acceptClicked() { finish(true) }
    @objc private func rejectClicked() { finish(false) }

    func windowWillClose(_ notification: Notification) {
        guard let decided else { return }
        self.decided = nil
        decided(false)
    }

    private func finish(_ accepted: Bool) {
        guard let decided else { return }
        self.decided = nil
        window.close()
        decided(accepted)
    }

    /// The changed lines, each with its line number, three lines of context and ⋯ for skipped lines.
    static func render(_ lines: [LineDiff.Line], font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func add(_ number: Int?, _ marker: String, _ text: String, background: NSColor?) {
            let prefix = number.map { String($0).leftPadded(to: 6) } ?? String(repeating: " ", count: 6)
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: TidepadTheme.editorText]
            if let background { attributes[.backgroundColor] = background }
            result.append(NSAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: TidepadTheme.gutterText]))
            result.append(NSAttributedString(string: " \(marker) \(text)\n", attributes: attributes))
        }
        let shown = LineDiff.hunks(lines, context: 3)
        if shown.isEmpty {
            result.append(NSAttributedString(string: "No changes.\n", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for entry in shown {
            switch entry {
            case nil:
                result.append(NSAttributedString(string: "     ⋯\n", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            case .same(let text, _, let new)?: add(new, " ", text, background: nil)
            case .removed(let text, let old)?: add(old, "−", text, background: NSColor.systemRed.withAlphaComponent(0.18))
            case .added(let text, let new)?: add(new, "+", text, background: NSColor.systemGreen.withAlphaComponent(0.18))
            }
        }
        return result
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
