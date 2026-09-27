import SwiftUI
import AppKit

struct SearchResultsView: View {
    let controller: SearchController
    var body: some View {
        let _ = EditorDiagnostics.view("SearchResultsView")
        let model = controller.results
        if model.visible {
            VStack(spacing: 0) {
                ChromeSeparator()
                HStack(spacing: 6) {
                    Button { model.collapsed.toggle() } label: { Image(systemName: model.collapsed ? "chevron.right" : "chevron.down") }
                    Text("Search results — \(model.summary)").lineLimit(1)
                    Spacer()
                    Button { model.visible = false } label: { Image(systemName: "xmark") }
                }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 6).frame(height: 23)
                if !model.collapsed {
                    ResultsTable(model: model, count: model.rows.count, activate: controller.activate).frame(height: 160)
                }
            }.background(Color(nsColor: TidepadTheme.tabStripBackground))
        }
    }
}

/// NSTableView requests only visible row views and reuses them as results arrive.
private struct ResultsTable: NSViewRepresentable {
    let model: SearchResultsModel
    let count: Int
    let activate: (SearchResult) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(model: model, activate: activate) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView(); table.headerView = nil; table.rowHeight = 19
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")))
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.action = #selector(Coordinator.clicked(_:))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let timer = SearchTiming("Result table update"); defer { timer.finish() }
        (view.documentView as? NSTableView)?.reloadData()
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: SearchResultsModel
        let activate: (SearchResult) -> Void
        init(model: SearchResultsModel, activate: @escaping (SearchResult) -> Void) { self.model = model; self.activate = activate }
        func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard model.rows.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("row")
            let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
            field.identifier = id; field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
            let result = model.rows[row]
            field.stringValue = "\(result.url?.lastPathComponent ?? result.name)  Ln \(result.line), Col \(result.column):  \(result.preview)"
            field.toolTip = "\(result.url?.path ?? result.name)\n\(field.stringValue)"
            return field
        }
        @objc func clicked(_ table: NSTableView) {
            guard model.rows.indices.contains(table.clickedRow) else { return }
            activate(model.rows[table.clickedRow])
        }
    }
}
