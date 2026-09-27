import SwiftUI
import AppKit

/// The terminal panel: a header with the shell's title and actions, and the terminal itself.
struct TerminalPanelView: View {
    let terminal: TerminalPanel
    /// Claude Code is connected to Tidepad.
    var claudeConnected = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: TidepadMetrics.toolbarSpacing) {
                Text("TERMINAL").font(.system(size: TidepadMetrics.tabFontSize, weight: .semibold))
                if !terminal.title.isEmpty {
                    Text(terminal.title)
                        .font(.system(size: TidepadMetrics.tabFontSize))
                        .foregroundStyle(Color(nsColor: TidepadTheme.inactiveTabText))
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.leading, TidepadMetrics.tabHorizontalPadding)
                }
                Spacer(minLength: 0)
                if claudeConnected {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Claude Code connected").font(.system(size: TidepadMetrics.tabFontSize))
                    }
                    .foregroundStyle(Color(nsColor: TidepadTheme.inactiveTabText))
                    .padding(.trailing, TidepadMetrics.tabHorizontalPadding)
                    .help("Claude Code sees the open folder, tabs and selection, and shows proposed changes for review")
                }
                button("New Shell", icon: "arrow.clockwise", action: terminal.restart)
                button("Hide Terminal (⌃`)", icon: "xmark", action: terminal.hide)
            }
            .padding(.leading, TidepadMetrics.tabHorizontalPadding + 2)
            .padding(.trailing, TidepadMetrics.toolbarGroupPadding)
            .frame(height: TidepadMetrics.tabBarHeight)
            .foregroundStyle(Color(nsColor: TidepadTheme.chromeText))
            .background(Color(nsColor: TidepadTheme.tabStripBackground))
            .overlay(alignment: .top) { ChromeSeparator() }
            .overlay(alignment: .bottom) { ChromeSeparator() }
            TerminalHostView(terminal: terminal)
        }
        .background(Color(nsColor: TidepadTheme.editorBackground))
    }

    private func button(_ title: String, icon: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: TidepadMetrics.tabIconSize))
                .frame(width: TidepadMetrics.tabCloseSize + 4, height: TidepadMetrics.tabCloseSize + 4)
        }
        .buttonStyle(CompactChromeButtonStyle()).help(title).accessibilityLabel(title)
    }
}

/// Hosts the terminal's AppKit view. The panel keeps the same view (and shell) while hidden.
struct TerminalHostView: NSViewRepresentable {
    let terminal: TerminalPanel
    func makeNSView(context: Context) -> TerminalView { terminal.view }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}
