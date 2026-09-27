import SwiftUI

struct DocumentTabView: View {
    let document: EditorDocument
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        let _ = EditorDiagnostics.view("DocumentTabView")
        HStack(spacing: TidepadMetrics.tabItemSpacing) {
            Button(action: select) {
                HStack(spacing: TidepadMetrics.tabItemSpacing) {
                    Image(systemName: "doc.text")
                        .font(.system(size: TidepadMetrics.tabIconSize))
                        .foregroundStyle(Color(nsColor: document.hasUnsavedChanges ? TidepadTheme.modified : TidepadTheme.fileIcon))
                    Text(document.displayName)
                        .font(.system(size: TidepadMetrics.tabFontSize, weight: selected ? .medium : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if document.hasUnsavedChanges {
                        Circle().fill(Color(nsColor: TidepadTheme.modified))
                            .frame(width: TidepadMetrics.dirtyIndicatorSize, height: TidepadMetrics.dirtyIndicatorSize)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: TidepadMetrics.tabCloseIconSize))
                    .frame(width: TidepadMetrics.tabCloseSize, height: TidepadMetrics.tabCloseSize)
            }
            .buttonStyle(CompactChromeButtonStyle())
            .help("Close \(document.displayName)")
            .accessibilityLabel("Close \(document.displayName)")
        }
        .foregroundStyle(Color(nsColor: selected ? TidepadTheme.activeTabText : TidepadTheme.inactiveTabText))
        .padding(.horizontal, TidepadMetrics.tabHorizontalPadding)
        .frame(minWidth: TidepadMetrics.tabMinimumWidth, maxWidth: TidepadMetrics.tabMaximumWidth)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: TidepadMetrics.tabHeight)
        .background(Color(nsColor: selected ? TidepadTheme.activeTabBackground : TidepadTheme.inactiveTabBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: selected ? TidepadTheme.tabAccent : TidepadTheme.separator))
                .frame(height: selected ? TidepadMetrics.tabAccentHeight : TidepadMetrics.separatorWidth)
        }
        .overlay(alignment: .trailing) { ChromeSeparator(vertical: true) }
        .overlay(alignment: .bottom) { if !selected { ChromeSeparator() } }
        .help(document.fileURL?.path ?? document.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
