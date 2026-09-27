import SwiftUI
import AppKit

/// The terminal panel: a header with a tab per terminal and the panel's actions, and the selected
/// terminal below it.
struct TerminalPanelView: View {
    let terminal: TerminalPanel
    /// Claude Code is connected to Tidepad.
    var claudeConnected = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: TidepadMetrics.toolbarSpacing) {
                Text("TERMINAL").font(.system(size: TidepadMetrics.tabFontSize, weight: .semibold))
                    .padding(.trailing, TidepadMetrics.tabHorizontalPadding)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(terminal.sessions) { session in tab(session) }
                    }
                }
                if claudeConnected {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Claude Code connected").font(.system(size: TidepadMetrics.tabFontSize)).lineLimit(1)
                    }
                    .foregroundStyle(Color(nsColor: TidepadTheme.inactiveTabText))
                    .padding(.horizontal, TidepadMetrics.tabHorizontalPadding)
                    .help("Claude Code sees the open folder, tabs and selection, and shows proposed changes for review")
                    .fixedSize()
                }
                button("New Terminal", icon: "plus", action: terminal.newTerminal)
                button("Restart Shell", icon: "arrow.clockwise", action: terminal.restart)
                button("Hide Terminal (⌃`)", icon: "chevron.down", action: terminal.hide)
            }
            .padding(.leading, TidepadMetrics.tabHorizontalPadding + 2)
            .padding(.trailing, TidepadMetrics.toolbarGroupPadding)
            .frame(height: TidepadMetrics.tabBarHeight)
            .foregroundStyle(Color(nsColor: TidepadTheme.chromeText))
            .background(Color(nsColor: TidepadTheme.tabStripBackground))
            .overlay(alignment: .top) { ChromeSeparator() }
            .overlay(alignment: .bottom) { ChromeSeparator() }
            TerminalHostView(session: terminal.selected)
        }
        .background(Color(nsColor: TidepadTheme.editorBackground))
    }

    private func tab(_ session: TerminalSession) -> some View {
        let selected = terminal.selected?.id == session.id
        return HStack(spacing: 4) {
            Button { terminal.select(session) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal").font(.system(size: TidepadMetrics.tabIconSize - 1))
                    Text(session.displayTitle).font(.system(size: TidepadMetrics.tabFontSize, weight: selected ? .medium : .regular))
                        .lineLimit(1).truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { terminal.close(session) } label: {
                Image(systemName: "xmark").font(.system(size: TidepadMetrics.tabCloseIconSize))
                    .frame(width: TidepadMetrics.tabCloseSize, height: TidepadMetrics.tabCloseSize)
            }
            .buttonStyle(CompactChromeButtonStyle())
            .help("Close \(session.displayTitle)")
            .accessibilityLabel("Close \(session.displayTitle)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .frame(maxWidth: TidepadMetrics.tabMaximumWidth, minHeight: TidepadMetrics.tabBarHeight - 6)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: selected ? TidepadTheme.activeTabBackground : .clear)))
        .foregroundStyle(Color(nsColor: selected ? TidepadTheme.activeTabText : TidepadTheme.inactiveTabText))
        .help(session.displayTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func button(_ title: String, icon: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: TidepadMetrics.tabIconSize))
                .frame(width: TidepadMetrics.tabCloseSize + 4, height: TidepadMetrics.tabCloseSize + 4)
        }
        .buttonStyle(CompactChromeButtonStyle()).help(title).accessibilityLabel(title)
    }
}

/// Hosts the selected terminal's AppKit view. Each terminal keeps its view (and shell) while another
/// tab is shown or the panel is hidden.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession?
    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.show(session?.view)
        return container
    }
    func updateNSView(_ nsView: TerminalContainerView, context: Context) { nsView.show(session?.view) }
}

/// Shows one terminal view at a time, filling the container.
final class TerminalContainerView: NSView {
    private weak var current: NSView?

    func show(_ view: NSView?) {
        guard view !== current else { return }
        current?.removeFromSuperview()
        if let view {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        current = view
    }
}
