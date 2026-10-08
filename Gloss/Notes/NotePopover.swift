import AppKit
import Core
import SwiftUI
import Viewers

/// Comment editor shown beside a selection or an existing highlight: what you are commenting on, the comment, its
/// colour, and the way out. Save is the one prominent action; Return saves, Shift-Return adds a line (standard enough
/// that the popover does not spell it out).
struct NotePopover: View {
    @State var state: NoteEditorState
    let onSave: (NoteEditorState) -> Void
    let onDelete: (NoteID) -> Void
    let onCancel: () -> Void
    /// The document's language, so the quoted code keeps the editor's colours; nil for prose and unknown files.
    var language: String? = nil
    /// The quote in colour, worked out once (building a highlighter compiles its queries), not on every keystroke.
    @State private var colouredQuote: AttributedString?

    private var tint: Color { Color(nsColor: Theme.color(for: state.color)) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Text(state.isNew ? "New note" : "Edit note")
                    .font(.headline)
                Spacer(minLength: DS.Space.s)
                Label(location, systemImage: state.anchor.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xxs)
                    .background(tint.opacity(0.14), in: Capsule())
            }
            if let quote = contextQuote {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Capsule().fill(tint.gradient).frame(width: 3)
                    // Code stays code: the quote keeps the editor's syntax colours, so it reads as the line you picked.
                    Group {
                        if let coloured = colouredQuote {
                            // Uncoloured text stays as quiet as the plain quote; tokens keep their colours.
                            Text(coloured).foregroundStyle(.secondary)
                        } else {
                            Text(quote).foregroundStyle(.secondary)
                        }
                    }
                        .font(.caption.monospaced())
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .help("The text this note is about")
                .task(id: quote) { colouredQuote = SyntaxTheme.highlighted(quote, language: language) }
            }
            ZStack(alignment: .topLeading) {
                NoteBodyEditor(text: $state.body, onSubmit: { if canSave { onSave(state) } }, onCancel: onCancel)
                if state.body.isEmpty {
                    Text("What should the agent know?")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 90, maxHeight: 220)
            .padding(DS.Space.s + 2)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(tint.opacity(0.45), lineWidth: 1))
            .animation(DS.Motion.snappy, value: state.body.isEmpty)
            if state.isNew, state.body.isEmpty {
                StarterPhrases { state.body = $0 }
                    .transition((AnyTransition.opacity.combined(with: .move(edge: .top))).calmed)
            }
            HStack(spacing: DS.Space.m) {
                ColorSwatches(selection: $state.color)
                Spacer(minLength: DS.Space.s)
                if let existing = state.existingID {
                    InlineIconButton(title: "Delete note", symbol: "trash", role: .destructive, emphasized: true) { onDelete(existing) }
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(state.isNew ? "Add Note" : "Save") { onSave(state) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .animation(DS.Motion.snappy, value: canSave)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 380)
        .animation(DS.Motion.smooth, value: state.color)
        .animation(DS.Motion.smooth, value: state.isNew && state.body.isEmpty)
    }

    /// Where the note sits: the anchor's line (or region, page, cells), and the characters when only part of one
    /// line is selected.
    private var location: String {
        guard let columns = state.columns else { return state.anchor.summary }
        let characters = columns.count == 1 ? "char \(columns.lowerBound)" : "chars \(columns.lowerBound)–\(columns.upperBound)"
        return "\(state.anchor.summary), \(characters)"
    }

    private var canSave: Bool { !state.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What the note is about, in a few words: the selected text, the cells, or nothing for regions and files.
    private var contextQuote: String? {
        guard case .text(let anchor) = state.anchor, anchor.cells == nil else { return nil }
        let lines = anchor.text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let text = lines.prefix(3).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text + (lines.count > 3 ? " …" : "")
    }
}

/// The usual ways a note to an agent begins, as chips under an empty note: one click writes the start of the
/// sentence and leaves the caret after it. They step aside as soon as there is text.
struct StarterPhrases: View {
    static let phrases: [(title: String, symbol: String, text: String)] = [
        ("Explain", "questionmark.bubble", "Explain what this does."),
        ("Fix", "wrench.adjustable", "Fix this: "),
        ("Add a test", "checkmark.seal", "Add a test that "),
        ("Why", "lightbulb", "Why does this "),
    ]
    let insert: (String) -> Void

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Self.phrases, id: \.title) { phrase in
                StarterChip(title: phrase.title, symbol: phrase.symbol) { insert(phrase.text) }
            }
        }
    }
}

private struct StarterChip: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(hovering ? 0.09 : 0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help("Start with “\(title)”")
    }
}

/// The note colours as swatches; the selection is a ring that slides to the chosen colour.
struct ColorSwatches: View {
    @Binding var selection: NoteColor
    @Namespace private var ring
    @State private var hovered: NoteColor?

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(NoteColor.allCases, id: \.self) { color in
                let fill = Color(nsColor: Theme.color(for: color))
                Button {
                    selection = color
                } label: {
                    Circle()
                        .fill(fill.gradient)
                        .frame(width: 14, height: 14)
                        .scaleEffect(hovered == color && selection != color ? 1.15 : 1)
                        .padding(3)
                        .overlay {
                            if selection == color {
                                Circle()
                                    .strokeBorder(fill, lineWidth: 2)
                                    .matchedGeometryEffect(id: "ring", in: ring)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help(color.rawValue.capitalized)
                .accessibilityLabel("\(color.rawValue.capitalized) note")
                .accessibilityAddTraits(selection == color ? .isSelected : [])
                .onHover { hovered = $0 ? color : (hovered == color ? nil : hovered) }
            }
        }
        .animation(DS.Motion.bouncy, value: selection)
        .animation(DS.Motion.snappy, value: hovered)
    }
}

/// A keyboard key, drawn as a small cap, for hints.
struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.s - 1, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.s - 1, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// The comment field: a plain NSTextView so Return can save while Shift-Return (and Option-Return) still insert
/// a newline, which SwiftUI's TextEditor cannot distinguish; Escape cancels. Takes focus when it appears. Shared by
/// the composer and a card's inline editor.
struct NoteBodyEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    var onCancel: () -> Void = {}
    /// Takes focus when it appears. A card's follow-up field, always there in an open card, waits to be asked.
    var focusesOnAppear = true
    /// Bumped to put the caret in a field that is already showing.
    var focusRequest = 0

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmitTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.focusesOnAppear = focusesOnAppear
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? SubmitTextView else { return }
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        if textView.string != text {
            textView.string = text
            // Setting `string` bypasses undo; older typing entries would now edit the wrong text.
            textView.undoManager?.removeAllActions(withTarget: textView)
            // Text set from outside (a starter phrase) leaves the caret at its end and the field focused, so
            // typing simply continues the sentence.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.window?.makeFirstResponder(textView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        /// The request last acted on; one made before the field existed is its `focusesOnAppear`.
        var focusRequest: Int

        init(text: Binding<String>, focusRequest: Int) {
            self.text = text
            self.focusRequest = focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }

    /// Return submits. Shift-Return has no binding of its own in the standard key bindings, so it arrives here as
    /// `insertNewline:` too and is told apart by the event's modifiers; Option-Return (`insertLineBreak:`) and
    /// Control-Return (`insertNewlineIgnoringFieldEditor:`) keep their normal newline behaviour.
    final class SubmitTextView: NSTextView {
        var onSubmit: () -> Void = {}
        var onCancel: () -> Void = {}
        var focusesOnAppear = true

        /// Escape. NSTextView would otherwise take it for word completion, so it never reached Cancel.
        override func cancelOperation(_ sender: Any?) {
            onCancel()
        }

        /// The popover's window exists only after the view is attached, so focus is claimed here rather than
        /// in `makeNSView`; typing right after the popover opens must land in the field.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if focusesOnAppear { window?.makeFirstResponder(self) }
        }

        override func insertNewline(_ sender: Any?) {
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.shift) || modifiers.contains(.option) || modifiers.contains(.control) {
                super.insertNewline(sender)
            } else {
                onSubmit()
            }
        }
    }
}
