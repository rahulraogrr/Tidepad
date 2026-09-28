import SwiftUI

struct WorkspaceView: View {
    let manager: DocumentManager
    let windowDelegate: TidepadAppDelegate
    let sessions: EditorSessionStore
    let preferences: EditorPreferences

    private var project: ProjectFolder { windowDelegate.project }
    private var terminal: TerminalPanel { windowDelegate.terminal }

    var body: some View {
        let _ = EditorDiagnostics.view("WorkspaceView")
        VStack(spacing: 0) {
            if preferences.showToolbar { EditorToolbar(context: windowDelegate.commandContext) }
            // The project sidebar and the editor, with a native draggable divider between them.
            HSplitView {
                if project.showSidebar {
                    ProjectSidebarView(project: project, manager: manager)
                        .frame(minWidth: TidepadMetrics.sidebarMinimumWidth, idealWidth: TidepadMetrics.sidebarIdealWidth,
                               maxWidth: TidepadMetrics.sidebarMaximumWidth)
                }
                editorColumn
                    .frame(minWidth: TidepadMetrics.editorMinimumWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
            if preferences.showStatusBar { StatusBarView(document: manager.selectedDocument) }
        }
        .frame(minWidth: TidepadMetrics.minimumWindowWidth, minHeight: TidepadMetrics.minimumWindowHeight)
        .background(Color(nsColor: TidepadTheme.editorBackground))
        .background(WindowDelegateBridge(delegate: windowDelegate))
        .onChange(of: manager.documents.map(\.id)) { _, ids in sessions.retainDocuments(Set(ids)) }
        // The full path of the current file, as Notepad++ shows it; ⌘-click the icon beside it for the
        // folders above it. Untitled tabs show their name.
        .navigationTitle(manager.selectedDocument.map { $0.fileURL?.path ?? $0.displayName }
                         ?? (project.url == nil ? "Tidepad" : project.name))
        .onChange(of: manager.selectedDocument?.fileURL, initial: true) { _, _ in windowDelegate.commandContext.syncWindowDocumentState() }
        .onChange(of: manager.documents.contains { $0.hasUnsavedChanges }, initial: true) { _, _ in
            windowDelegate.commandContext.syncWindowDocumentState()
        }
    }

    /// The editor, with the terminal panel below it when shown and a native draggable divider between.
    private var editorColumn: some View {
        VSplitView {
            editorArea.frame(minHeight: TidepadMetrics.editorMinimumHeight, maxHeight: .infinity)
            if terminal.isVisible {
                TerminalPanelView(terminal: terminal, claudeConnected: windowDelegate.claude.connectedClients > 0)
                    .frame(minHeight: TidepadMetrics.terminalMinimumHeight, idealHeight: TidepadMetrics.terminalIdealHeight)
            }
        }
    }

    /// The tab bar's buttons, at its right end as in Notepad++: a new tab, a menu of every open tab
    /// (for finding one when there are more than fit), and closing the current tab.
    private var tabBarActions: some View {
        HStack(spacing: 0) {
            Button(action: manager.newDocument) {
                Image(systemName: "plus").font(.system(size: TidepadMetrics.tabIconSize))
                    .frame(width: TidepadMetrics.tabBarHeight, height: TidepadMetrics.tabBarHeight)
            }
            .buttonStyle(CompactChromeButtonStyle()).help("New document (⌘N)")
            .accessibilityLabel("New document")
            Menu {
                ForEach(manager.documents) { document in
                    Toggle(isOn: Binding(get: { manager.selectedID == document.id }, set: { _ in manager.selectedID = document.id })) {
                        Text(document.hasUnsavedChanges ? "\(document.displayName) •" : document.displayName)
                    }
                    .help(document.fileURL?.path ?? document.displayName)
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: TidepadMetrics.tabCloseIconSize, weight: .semibold))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: TidepadMetrics.tabBarHeight, height: TidepadMetrics.tabBarHeight)
            .disabled(manager.documents.isEmpty)
            .help("Show all tabs").accessibilityLabel("Show all tabs")
            Button {
                if let document = manager.selectedDocument { manager.close(document) }
            } label: {
                Image(systemName: "xmark").font(.system(size: TidepadMetrics.tabIconSize))
                    .frame(width: TidepadMetrics.tabBarHeight, height: TidepadMetrics.tabBarHeight)
            }
            .buttonStyle(CompactChromeButtonStyle()).help("Close tab (⌘W)")
            .accessibilityLabel("Close tab")
            .disabled(manager.selectedDocument == nil)
        }
        .padding(.trailing, TidepadMetrics.toolbarGroupPadding)
    }

    private var editorArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(manager.documents) { document in
                                DocumentTabView(document: document, selected: manager.selectedID == document.id,
                                                select: { manager.selectedID = document.id },
                                                close: { manager.close(document) })
                            }
                            // Double-clicking the empty part of the tab bar opens a new tab, as in Safari,
                            // Terminal and Notepad++.
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { manager.newDocument() }
                                .accessibilityHidden(true)
                        }
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .leading)
                    }
                }
                tabBarActions
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
                        Button("Open folder…", action: project.chooseAndOpen)
                    }.buttonStyle(CompactChromeButtonStyle())
                }
                .font(.system(size: TidepadMetrics.tabFontSize))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, _ in openDropped(urls) }
            }
            SearchResultsView(controller: windowDelegate.commandContext.search)
        }
    }

    /// Dropped folders open as the project; dropped files open in tabs.
    private func openDropped(_ urls: [URL]) -> Bool {
        let items = urls.filter(\.isFileURL)
        guard !items.isEmpty else { return false }
        windowDelegate.open(items)
        return true
    }
}
