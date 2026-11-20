import Defaults
import SwiftUI

struct TerminalShortcutsSettings: View {
    let highlightID: String

    @Default(.terminalShortcuts) private var shortcuts
    @State private var draft: TerminalShortcut?

    var body: some View {
        Section {
            ForEach(shortcuts) { shortcut in
                if let draft, draft.id == shortcut.id {
                    editor(draft)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(shortcut.name)
                                .lineLimit(1)
                            Text(shortcut.command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { beginEditing(shortcut) }
                        .accessibilityAction(named: Text("Edit")) { beginEditing(shortcut) }
                        .contextMenu {
                            Button("Edit") { beginEditing(shortcut) }
                                .disabled(draft != nil)
                        }
                        .help(shortcut.command)

                        Button(role: .destructive) {
                            shortcuts.removeAll { $0.id == shortcut.id }
                        } label: {
                            Label("Delete", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete")
                    }
                }
            }

            if let draft, !shortcuts.contains(where: { $0.id == draft.id }) {
                editor(draft)
            }

            Button {
                beginEditing(TerminalShortcut())
            } label: {
                Label("Add shortcut", systemImage: "plus")
            }
            .disabled(draft != nil)
            .settingsHighlight(id: highlightID)
        } header: {
            Text("Terminal shortcuts")
        } footer: {
            Text("Double-click a shortcut to edit its name and command.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func editor(_ shortcut: TerminalShortcut) -> some View {
        TerminalShortcutEditor(shortcut: shortcut, onSave: save, onCancel: { draft = nil })
            .id(shortcut.id)
    }

    private func beginEditing(_ shortcut: TerminalShortcut) {
        guard draft == nil else { return }
        draft = shortcut
    }

    private func save(_ shortcut: TerminalShortcut) {
        guard shortcut.isValid else { return }
        if let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts[index] = shortcut
        } else {
            shortcuts.append(shortcut)
        }
        draft = nil
    }
}

private struct TerminalShortcutEditor: View {
    @State var shortcut: TerminalShortcut
    let onSave: (TerminalShortcut) -> Void
    let onCancel: () -> Void
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $shortcut.name)
                .focused($isNameFocused)
            TextField("Shell command", text: $shortcut.command)
                .font(.system(.body, design: .monospaced))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(shortcut) }
                    .disabled(!shortcut.isValid)
            }
            .buttonStyle(.bordered)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { isNameFocused = true }
        .onSubmit {
            if shortcut.isValid {
                onSave(shortcut)
            }
        }
    }
}
