import Core
import SwiftUI
import Viewers

/// Comment editor shown beside a selection or an existing highlight.
struct NotePopover: View {
    @State var state: NoteEditorState
    let onSave: (NoteEditorState) -> Void
    let onDelete: (NoteID) -> Void
    let onCancel: () -> Void
    @FocusState private var bodyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.isNew ? "New note" : "Edit note")
                    .font(.headline)
                Spacer()
                Text(state.anchor.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $state.body)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .focused($bodyFocused)
            HStack(spacing: 8) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    Circle()
                        .fill(Color(nsColor: Theme.color(for: color)))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.primary.opacity(state.color == color ? 0.8 : 0), lineWidth: 2))
                        .onTapGesture { state.color = color }
                        .help(color.rawValue)
                }
                Spacer()
                if let existing = state.existingID {
                    Button("Delete", role: .destructive) { onDelete(existing) }
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(state) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(state.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Markdown. ⌘↩ saves.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 380)
        .onAppear { bodyFocused = true }
    }
}
