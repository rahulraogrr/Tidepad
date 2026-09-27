import SwiftUI

struct ChromeSeparator: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Color(nsColor: TidepadTheme.separator))
            .frame(width: vertical ? TidepadMetrics.separatorWidth : nil,
                   height: vertical ? nil : TidepadMetrics.separatorWidth)
            .accessibilityHidden(true)
    }
}

struct CompactChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Color(nsColor: configuration.isPressed ? TidepadTheme.buttonPressed :
                                    hovering && enabled ? TidepadTheme.buttonHover : .clear))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.35)
                .onHover { hovering = $0 }
        }
    }
}
