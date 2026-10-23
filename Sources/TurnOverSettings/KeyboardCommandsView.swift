// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import TurnOverControl

struct KeyboardCommandsView: View {
    @ObservedObject var editor: KeyboardEditorModel
    @State private var search = ""
    private enum Category: Hashable {
        case all, changed, commands(String)
    }
    @State private var category: Category? = .all
    @State private var selection: String?
    @State private var changedSelection: String?
    @State private var edit: KeyboardEditRequest?
    @AccessibilityFocusState private var addKeyFocused: Bool

    private var commands: [KeyboardEditing.Command] { editor.state?.commands ?? [] }
    private var selected: KeyboardEditing.Command? { filtered.first { $0.id == selection } }
    private var categories: [String] { Array(Set(commands.map(\.category))).sorted() }
    private var filtered: [KeyboardEditing.Command] {
        commands.filter { command in
            (category == .all || category == .commands(command.category)) &&
            (search.isEmpty || ([command.title, command.category] + command.keys.map(\.label)).contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let state = editor.state {
                Text("\(state.style) · \(state.layout.capitalized) · \(state.context)").foregroundStyle(.secondary)
            }
            HSplitView {
                List(selection: $category) {
                    Text("All commands").tag(Category.all)
                    Text("Changed keys").tag(Category.changed)
                    Section("Categories") {
                        ForEach(categories, id: \.self) { Text($0).tag(Category.commands($0)) }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Command categories")
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 230)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search commands or keys", text: $search)
                        .textFieldStyle(.roundedBorder)
                    if category == .changed {
                        changedKeys
                    } else {
                        commandList
                        commandDetail
                    }
                }
                .frame(minWidth: 360)
                .padding(.leading, 8)
            }
            if !editor.message.isEmpty {
                Text(editor.message).font(.callout).accessibilityLabel(editor.message)
            }
            Text("App and document commands come from the app where you opened Settings. Open Settings there again to refresh them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .navigationTitle("Keyboard commands")
        .onAppear { editor.refresh() }
        .onChange(of: category) { _, _ in selection = nil; changedSelection = nil }
        .sheet(item: $edit, onDismiss: { addKeyFocused = true }) { request in
            KeyboardRecordingView(editor: editor, request: request)
        }
    }

    private var commandList: some View {
        List(selection: $selection) {
            ForEach(Array(Set(filtered.map(\.category))).sorted(), id: \.self) { category in
                Section(category) {
                    ForEach(filtered.filter { $0.category == category }) { command in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(command.title).lineLimit(2)
                            Text(command.keys.isEmpty ? "No key assigned" : command.keys.map(\.label).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .tag(command.id)
                    }
                }
            }
        }
        .accessibilityLabel("Commands by category")
        .frame(minHeight: 120)
        .overlay {
            if filtered.isEmpty { Text(editor.state == nil ? "Loading commands…" : "No matching commands").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var commandDetail: some View {
        if let command = selected {
            Divider()
            Text(command.title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if command.keys.isEmpty { Text("No key assigned").foregroundStyle(.secondary) }
                    ForEach(command.keys) { key in
                        HStack {
                            Text(key.label + (key.custom ? " (custom)" : ""))
                            Spacer()
                            if key.editable {
                                Button("Change…") { edit = .init(command: command, oldKey: key) }
                                    .accessibilityLabel("Change \(key.label)")
                                Button("Remove") { editor.remove(key, from: command) }
                                    .accessibilityLabel("Remove \(key.label)")
                            } else {
                                Text("Essential key").foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(120, max(28, CGFloat(command.keys.count) * 36)))
            Button("Add key…") { edit = .init(command: command) }
                .accessibilityFocused($addKeyFocused)
        } else {
            Text("Select a command to add, change or remove its keys.").foregroundStyle(.secondary)
        }
    }

    private var changedKeys: some View {
        let changes = (editor.state?.changes ?? []).filter {
            search.isEmpty || ($0.label + " " + $0.target).localizedCaseInsensitiveContains(search)
        }
        return VStack(alignment: .leading, spacing: 8) {
            List(selection: $changedSelection) {
                ForEach(changes) { change in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(change.label).font(.headline)
                        Text(change.target)
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.vertical, 4)
                    .tag(change.id)
                }
            }
            .accessibilityLabel("Changed keys")
            .overlay {
                if changes.isEmpty { Text("No changed keys").foregroundStyle(.secondary) }
            }
            if let change = changes.first(where: { $0.id == changedSelection }) {
                Button("Restore default for \(change.label)") { editor.restore(change) }
            } else if !changes.isEmpty {
                Text("Select a changed key to restore its default.").foregroundStyle(.secondary)
            }
        }
    }
}
