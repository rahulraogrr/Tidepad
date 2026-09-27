import SwiftUI
import AppKit

/// The project sidebar: the folder's name with a few actions, and its file tree.
struct ProjectSidebarView: View {
    let project: ProjectFolder
    let manager: DocumentManager

    var body: some View {
        VStack(spacing: 0) {
            if project.url == nil { noFolder } else { folder }
        }
        .background(Color(nsColor: TidepadTheme.sidebarBackground))
    }

    /// With no folder open: Open Folder, and the recent folders.
    private var noFolder: some View {
        VStack(alignment: .leading, spacing: TidepadMetrics.tabHorizontalPadding) {
            Text("NO FOLDER OPEN")
                .font(.system(size: TidepadMetrics.tabFontSize, weight: .semibold))
                .frame(height: TidepadMetrics.tabBarHeight)
            Button("Open Folder…", action: project.chooseAndOpen)
            if !project.recentFolders.isEmpty {
                Text("Recent").font(.system(size: TidepadMetrics.tabFontSize, weight: .semibold))
                    .foregroundStyle(Color(nsColor: TidepadTheme.inactiveTabText))
                    .padding(.top, TidepadMetrics.tabHorizontalPadding)
                ForEach(project.recentFolders.prefix(8), id: \.self) { url in
                    Button(url.lastPathComponent) { project.open(url) }
                        .buttonStyle(.link).help(url.path)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: TidepadMetrics.tabFontSize + 1))
        .foregroundStyle(Color(nsColor: TidepadTheme.chromeText))
        .padding(.horizontal, TidepadMetrics.tabHorizontalPadding + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var folder: some View {
        VStack(spacing: 0) {
            HStack(spacing: TidepadMetrics.toolbarSpacing) {
                Text(project.name.uppercased())
                    .font(.system(size: TidepadMetrics.tabFontSize, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(project.url?.path ?? "")
                Spacer(minLength: 0)
                button("New File", icon: "doc.badge.plus") { project.createItem?(false) }
                button("New Folder", icon: "folder.badge.plus") { project.createItem?(true) }
                button(project.showIgnored ? "Hide Ignored Files" : "Show Ignored Files",
                       icon: project.showIgnored ? "eye" : "eye.slash") { project.showIgnored.toggle() }
                button("Open in Terminal", icon: "terminal") {
                    if let url = project.url { FileTreeController.openTerminal(at: url) }
                }
                button("Close Folder", icon: "xmark", action: project.close)
            }
            .padding(.leading, TidepadMetrics.tabHorizontalPadding + 2)
            .padding(.trailing, TidepadMetrics.toolbarGroupPadding)
            .frame(height: TidepadMetrics.tabBarHeight)
            .foregroundStyle(Color(nsColor: TidepadTheme.chromeText))
            .background(Color(nsColor: TidepadTheme.tabStripBackground))
            .overlay(alignment: .bottom) { ChromeSeparator() }
            FileTreeView(project: project, generation: project.generation, selectedFile: manager.selectedDocument?.fileURL,
                         openFile: { manager.openInBackground([$0]) })
        }
    }

    private func button(_ title: String, icon: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: TidepadMetrics.tabIconSize))
                .frame(width: TidepadMetrics.tabCloseSize + 4, height: TidepadMetrics.tabCloseSize + 4)
        }
        .buttonStyle(CompactChromeButtonStyle()).help(title).accessibilityLabel(title)
    }
}

/// Hosts the AppKit file tree in SwiftUI.
struct FileTreeView: NSViewRepresentable {
    let project: ProjectFolder
    /// Passed in so SwiftUI updates the tree when the folder or the ignore setting changes.
    let generation: Int
    let selectedFile: URL?
    let openFile: @MainActor (URL) -> Void

    func makeCoordinator() -> FileTreeController { FileTreeController(project: project, openFile: openFile) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update(selectedFile: selectedFile)
        return context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(selectedFile: selectedFile)
    }
}
