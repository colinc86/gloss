import Core
import SwiftUI
import Viewers

/// The compact layout's notes (2026-10-11): a tray under the document. Closed, it is one line: the note in hand with
/// "3 of 8" and steps through what the panel lists in this location, and Send. Open, it is the whole notes panel, as
/// tall as it was last dragged.
struct NotesTray: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: Double?
    /// The height while dragging; saved to Settings once the drag ends, not on every step.
    @State private var dragHeight: Double?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if model.showNotesPanel { open } else { bar }
        }
        .background(.bar)
        .animation(DS.Motion.smooth, value: model.showNotesPanel)
    }

    // MARK: Closed

    /// The notes the panel lists in this location, in its order across files.
    private var listed: [(note: Note, document: Core.Document)] {
        model.notesPanel.visibleGroups.flatMap { group in group.notes.map { (note: $0, document: group.document) } }
    }

    private var bar: some View {
        let notes = listed
        let index = model.notesPanel.selectedNoteID.flatMap { id in notes.firstIndex { $0.note.id == id } }
        let current = index.map { notes[$0] }
        return HStack(spacing: DS.Space.s) {
            if let current {
                Capsule().fill(Color(nsColor: Theme.color(for: current.note.color)).gradient).frame(width: 3, height: 18)
                Text(current.note.anchor.summary)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(Self.firstLine(current.note.body))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                NoteCard.badge(current.note)
            } else {
                Label(notes.isEmpty ? "No notes here" : (notes.count == 1 ? "1 note" : "\(notes.count) notes"), systemImage: "note.text")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.s)
            if !notes.isEmpty {
                HStack(spacing: DS.Space.xxs) {
                    InlineIconButton(title: "Previous note", symbol: "chevron.left", emphasized: false) { step(notes, from: index, by: -1) }
                    Text(index.map { "\($0 + 1) of \(notes.count)" } ?? "\(notes.count)")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .fixedSize()
                    InlineIconButton(title: "Next note", symbol: "chevron.right", emphasized: false) { step(notes, from: index, by: 1) }
                }
            }
            let drafts = model.visibleDrafts.count
            Button { Task { await model.sendVisibleDrafts() } } label: {
                Label(drafts > 0 ? "Send \(drafts)" : "Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(drafts == 0 || !model.send.isTargetAvailable || model.send.isSending)
            .help(model.send.lastTarget.map { "Send the shown drafts to \($0.label)" } ?? "Choose an agent in the notes panel")
            InlineIconButton(title: "Show notes", symbol: "chevron.up", emphasized: false) { model.showNotesPanel = true }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notes tray")
    }

    /// Steps to the note before or after the one in hand, wrapping, and shows it in its document.
    private func step(_ notes: [(note: Note, document: Core.Document)], from index: Int?, by offset: Int) {
        guard let next = Self.stepped(count: notes.count, from: index, by: offset) else { return }
        let target = notes[next]
        model.notesPanel.selectedNoteID = target.note.id
        model.reveal(note: target.note, in: target.document, select: false)
    }

    /// The index after (or before) `index` among `count` notes, wrapping; from none, the first (or the last).
    static func stepped(count: Int, from index: Int?, by offset: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return offset > 0 ? 0 : count - 1 }
        return ((index + offset) % count + count) % count
    }

    static func firstLine(_ body: String) -> String {
        body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
    }

    // MARK: Open

    private var open: some View {
        // Never more of the window than the drag allows, however tall it was dragged in a taller window.
        let height = min(dragHeight ?? model.settings.compactTrayHeight, max(200, model.layout.height * 0.6))
        return VStack(spacing: 0) {
            handle
            NotesPanel()
        }
        .frame(height: height)
    }

    /// Dragged to size the tray; its chevron puts it back to the bar.
    private var handle: some View {
        ZStack {
            Capsule().fill(.tertiary).frame(width: 36, height: 4)
            HStack {
                Spacer()
                InlineIconButton(title: "Hide notes", symbol: "chevron.down", emphasized: false) { model.showNotesPanel = false }
            }
            .padding(.horizontal, DS.Space.s)
        }
        .frame(height: 18)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? model.settings.compactTrayHeight
                    if dragStart == nil { dragStart = start }
                    let limit = max(200, model.layout.height * 0.6)
                    dragHeight = min(max(200, start - value.translation.height), limit)
                }
                .onEnded { _ in
                    if let dragHeight { model.settings.compactTrayHeight = dragHeight }
                    dragStart = nil
                    dragHeight = nil
                }
        )
        .pointerStyle(.rowResize)
        .accessibilityLabel("Notes tray height")
    }
}
