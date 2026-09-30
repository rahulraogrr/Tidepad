import SwiftUI
import AppKit

struct SearchPanelView: View {
    @Bindable var controller: SearchController
    @FocusState private var findFocused: Bool
    var body: some View {
        let _ = EditorDiagnostics.view("SearchPanelView")
        VStack(alignment: .leading, spacing: 9) {
            Picker("Search", selection: $controller.tab) {
                ForEach(SearchController.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                GridRow {
                    Text("Find what:").frame(width: 88, alignment: .trailing)
                    historyField("Find text", value: $controller.query.text, history: controller.history.finds).focused($findFocused)
                }
                if controller.tab == .replace {
                    GridRow {
                        Text("Replace with:").frame(width: 88, alignment: .trailing)
                        historyField("Replacement", value: $controller.replacement, history: controller.history.replacements)
                    }
                }
                if controller.tab == .files {
                    GridRow {
                        Text("Directory:").frame(width: 88, alignment: .trailing)
                        HStack(spacing: 4) {
                            historyField("Directory", value: $controller.directory, history: controller.history.directories)
                            Button("Browse…", action: controller.chooseDirectory)
                        }
                    }
                    GridRow {
                        Text("Filters:").frame(width: 88, alignment: .trailing)
                        historyField("*.java;*.xml", value: $controller.filters, history: controller.history.filters)
                    }
                }
            }
            HStack(spacing: 14) {
                Toggle("Match case", isOn: $controller.query.matchCase)
                Toggle("Whole word", isOn: $controller.query.wholeWord)
                if controller.tab != .files { Toggle("Wrap around", isOn: $controller.query.wrap) }
            }.toggleStyle(.checkbox)
            Picker("Search mode:", selection: $controller.query.mode) {
                ForEach(SearchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.radioGroup).horizontalRadioGroupLayout()
            HStack(spacing: 6) {
                if controller.tab == .files {
                    Button("Find All", action: controller.findInFiles).disabled(!controller.canSearch || controller.directory.isEmpty)
                    Button("Cancel", action: controller.cancelFiles).disabled(!controller.filesBusy)
                    if controller.filesBusy { ProgressView().controlSize(.small); Text("\(controller.fileCount) files") }
                } else {
                    Group {
                        Button("Find Next") { controller.navigate() }.keyboardShortcut(.return, modifiers: [])
                        if controller.tab == .find {
                            Button("Find Previous") { controller.navigate(backwards: true) }
                            Button("Count") { controller.findAll(countOnly: true) }
                            Button("Find All in Current Document") { controller.findAll() }
                        } else {
                            Button("Replace") { controller.replace() }
                            Button("Replace + Find") { controller.replace(findNext: true) }
                            Button("Replace All") { controller.replace(all: true) }
                            Button("Replace All in Selection") { controller.replace(all: true, inSelection: true) }.help("Replace All in Selection")
                        }
                    }.disabled(!controller.canSearch || !controller.hasDocument)
                }
            }
            if controller.busy {
                HStack { ProgressView().controlSize(.small); Text("Searching…"); Button("Cancel", action: controller.cancelDocumentSearch) }
            }
            Text(controller.validationError ?? (controller.tab == .files ? controller.results.summary : controller.message))
                .foregroundStyle(controller.validationError == nil ? Color.secondary : Color.red)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if controller.tab == .files {
                Text("Skips binary, unreadable, unsupported-encoding files and files over 64 MB. Results limited to 100,000.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11)).controlSize(.small).padding(12)
        .frame(width: 640, height: controller.panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { findFocused = true }
        .onChange(of: controller.tab) { _, _ in findFocused = true }
    }
    private func historyField(_ title: String, value: Binding<String>, history: [String]) -> some View {
        HStack(spacing: 2) {
            TextField(title, text: value).textFieldStyle(.roundedBorder)
            Menu { ForEach(history, id: \.self) { entry in Button(entry) { value.wrappedValue = entry } } } label: {
                Image(systemName: "clock.arrow.circlepath")
            }.menuStyle(.borderlessButton).frame(width: 22).disabled(history.isEmpty).help("Session history")
        }
    }
}

struct GoToLineView: View {
    let document: EditorDocument
    let go: (String) -> Bool
    let cancel: () -> Void
    @State private var input = ""
    @State private var error = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Line:"); TextField("Line number", text: $input).focused($focused) }
            Text("Valid range: 1 – \(document.lineCount)").foregroundStyle(.secondary)
            if error { Text("Enter a valid line for the active document.").foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Go") { error = !go(input) }.keyboardShortcut(.defaultAction) }
        }.font(.system(size: 11)).controlSize(.small).padding(12).frame(width: 300)
            .onAppear { input = "\(document.cursorLine)"; focused = true }
    }
}
