import SwiftUI

struct WorkspaceView: View {
    let manager: DocumentManager
    let windowDelegate: TidepadAppDelegate
    let sessions: EditorSessionStore
    let preferences: EditorPreferences

    var body: some View {
        let _ = EditorDiagnostics.view("WorkspaceView")
        VStack(spacing: 0) {
            if preferences.showToolbar { EditorToolbar(manager: manager, sessions: sessions, find: { windowDelegate.commandContext.search.show(.find) }) }
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(manager.documents) { document in
                            DocumentTabView(document: document, selected: manager.selectedID == document.id,
                                            select: { manager.selectedID = document.id },
                                            close: { manager.close(document) })
                        }
                    }
                }
                Button(action: manager.newDocument) {
                    Image(systemName: "plus").font(.system(size: TidepadMetrics.tabIconSize))
                        .frame(width: TidepadMetrics.tabBarHeight, height: TidepadMetrics.tabBarHeight)
                }
                .buttonStyle(CompactChromeButtonStyle()).help("New document (⌘N)")
                .accessibilityLabel("New document")
            }
            .frame(height: TidepadMetrics.tabBarHeight)
            .dropDestination(for: URL.self) { urls, _ in openDropped(urls) }
            .foregroundStyle(Color(nsColor: TidepadTheme.chromeText))
            .background(alignment: .bottom) {
                Color(nsColor: TidepadTheme.tabStripBackground)
                    .overlay(alignment: .bottom) { ChromeSeparator() }
            }
            if let document = manager.selectedDocument {
                EditorView(document: document, sessions: sessions, preferences: preferences)
            } else {
                VStack(spacing: TidepadMetrics.tabHorizontalPadding) {
                    Text("No open documents").foregroundStyle(Color(nsColor: TidepadTheme.inactiveTabText))
                    HStack(spacing: TidepadMetrics.tabHorizontalPadding) {
                        Button("New document", action: manager.newDocument)
                        Button("Open file…", action: manager.open)
                    }.buttonStyle(CompactChromeButtonStyle())
                }
                .font(.system(size: TidepadMetrics.tabFontSize))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, _ in openDropped(urls) }
            }
            SearchResultsView(controller: windowDelegate.commandContext.search)
            if preferences.showStatusBar { StatusBarView(document: manager.selectedDocument) }
        }
        .frame(minWidth: TidepadMetrics.minimumWindowWidth, minHeight: TidepadMetrics.minimumWindowHeight)
        .background(Color(nsColor: TidepadTheme.editorBackground))
        .background(WindowDelegateBridge(delegate: windowDelegate))
        .onChange(of: manager.documents.map(\.id)) { _, ids in sessions.retainDocuments(Set(ids)) }
        .navigationTitle(manager.selectedDocument?.displayName ?? "Tidepad")
        .onChange(of: manager.selectedDocument?.fileURL, initial: true) { _, _ in windowDelegate.commandContext.syncWindowDocumentState() }
        .onChange(of: manager.documents.contains { $0.hasUnsavedChanges }, initial: true) { _, _ in
            windowDelegate.commandContext.syncWindowDocumentState()
        }
    }

    private func openDropped(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        manager.openInBackground(files)
        return true
    }
}
