import Core
import SwiftUI
import Viewers

/// Review mode's card, floating over the bottom of the document as the peek and the send toast do: the note on
/// screen as its card shows it (color rail, place, state pill), what the user asked and what the agent said it did,
/// then the steps between notes and Accept, Follow Up and Later. The document above stays editable, so Accept has no
/// key of its own.
struct ReviewBar: View {
    @Environment(AppModel.self) private var model
    var onCardFrameChange: (CGRect) -> Void = { _ in }
    @State private var composing = false
    @State private var followUpText = ""
    @State private var followUpFailed = false
    @State private var confirmingAcceptAll = false

    private var review: ReviewModel { model.review }
    private static let shape = RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)

    var body: some View {
        Group {
            if let current = review.current {
                noteCard(current.note, current.document)
            } else if review.isFinished {
                finished
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        // As tall as what it holds: the rail and the bubble would otherwise take the whole document's height.
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { progress }
        .readableGlass(in: Self.shape)
        .clipShape(Self.shape)
        // The card floats above the document in its own host; without this the text's I-beam shows through.
        .pointerStyle(.default)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        .frame(maxWidth: 560)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ReviewOverlay.space)) } action: { onCardFrameChange($0) }
        .padding(DS.Space.l)
        .animation(DS.Motion.smooth, value: review.current?.note.id)
        .animation(DS.Motion.smooth, value: review.isFinished)
        .animation(DS.Motion.smooth, value: composing)
        .onExitCommand { composing ? cancelFollowUp() : review.end() }
        .onChange(of: review.current?.note.id) { _, _ in cancelFollowUp() }
        .onChange(of: review.remaining) { _, _ in review.skipMissing() }
        .disabled(review.isBusy)
        .confirmationDialog("Accept \(review.remaining.count) results?", isPresented: $confirmingAcceptAll) {
            Button("Accept \(review.remaining.count)") { Task { await review.acceptAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every note left in this review is marked as reviewed.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(review.current == nil ? "Review" : "Review, note \(review.index + 1) of \(review.queue.count)")
    }

    // MARK: The note

    private func noteCard(_ note: Note, _ document: Core.Document) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Capsule()
                .fill(Color(nsColor: Theme.color(for: note.color)).gradient)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                header(note, document)
                content(note)
                    .id(note.id)
                    .transition(.opacity.calmed)
                if composing { composer } else { controls }
            }
        }
    }

    private func header(_ note: Note, _ document: Core.Document) -> some View {
        HStack(spacing: DS.Space.s) {
            Label(note.anchor.summary, systemImage: note.anchor.symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("· \(document.fileName)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Space.xs)
            if note.resolveOutcome == .skipped, note.state == .resolved {
                StatusPill(label: "Skipped", symbol: "arrow.uturn.right.circle.fill", tint: .orange)
            }
            NoteCard.badge(note)
                .id(NoteCard.badgeLabel(note))
                .transition((AnyTransition.scale(scale: 0.85).combined(with: .opacity)).calmed)
            InlineIconButton(title: "Stop reviewing", symbol: "xmark", emphasized: false) { review.end() }
        }
    }

    private func content(_ note: Note) -> some View {
        let thread = NoteThread(comment: note.body, messages: model.notesPanel.messages(for: note.id))
        // This round's word only: an earlier round's reply, or a status update before resolving, isn't what it did.
        let reply = note.resolveMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let asked = thread.turns.last { $0.speaker == .user && !$0.unsent }?.text ?? thread.comment
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(NoteCard.styledBody(asked))
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
            if note.state != .resolved, let followUp = thread.turns.last(where: { $0.speaker == .user }) {
                // Followed up in this review: the user's turn, as the card's thread shows it.
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(spacing: DS.Space.xs) {
                        Text("You").foregroundStyle(Color.accentColor)
                        if followUp.unsent { Text("Not sent").fontWeight(.regular).foregroundStyle(.secondary) }
                    }
                    .font(.caption2.weight(.semibold))
                    Text(NoteCard.styledBody(followUp.text))
                        .font(.callout)
                        .lineLimit(3)
                }
                .accessibilityElement(children: .combine)
            } else if let reply {
                AgentMessageBubble(message: reply, asks: false, agent: note.resolveAgent)
                    .frame(maxHeight: 140)
            } else {
                Text("Resolved without a message")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s) {
                navigator
                acceptAll
                Spacer(minLength: DS.Space.m)
                actions
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    navigator
                    Spacer(minLength: 0)
                    acceptAll
                }
                HStack {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .controlSize(.small)
    }

    private var navigator: some View {
        HStack(spacing: DS.Space.xxs) {
            InlineIconButton(title: "Previous note", symbol: "chevron.left", emphasized: false) { review.previous() }
                .disabled(!review.canGoBack)
            Text("\(review.index + 1) of \(review.queue.count)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .fixedSize()
            InlineIconButton(title: "Next note to review", symbol: "chevron.right", emphasized: false) { review.next() }
                .disabled(!review.canGoForward)
        }
    }

    @ViewBuilder
    private var acceptAll: some View {
        if review.remaining.count > 1 {
            // A plain button, not grey text: grey read as disabled.
            Button("Accept All…") { confirmingAcceptAll = true }
                .help("Accept every note left in this review")
        }
    }

    /// The note's actions while it waits; once reviewed its pill says what happened, and only the steps remain.
    @ViewBuilder
    private var actions: some View {
        if !review.isCurrentReviewed {
            HStack(spacing: DS.Space.s) {
                if review.remaining.count > 1 {
                    Button("Later") { review.later() }
                        .help("Come back to this note at the end")
                }
                Button("Follow Up…") { composing = true }
                    .help("Reply to the agent; the note reopens and goes with your next Send")
                Button("Accept") { Task { await review.accept() } }
                    .buttonStyle(.glassProminent)
                    .help("The result is what you asked for")
            }
            .transition(.opacity.calmed)
        }
    }

    /// The card's follow-up composer: Return adds it, Shift-Return a new line, Escape cancels.
    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            NoteBodyEditor(text: $followUpText, onSubmit: commitFollowUp, onCancel: cancelFollowUp, owner: review.current?.note.id)
                .frame(minHeight: 28, maxHeight: 120)
                .padding(DS.Space.xs)
                .overlay(alignment: .topLeading) {
                    if followUpText.isEmpty {
                        Text("Follow up")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, DS.Space.xs + 5)
                            .padding(.top, DS.Space.xs + 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .accessibilityLabel("Follow up")
            if followUpFailed {
                Label("The follow-up couldn't be added. It's still here.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancelFollowUp)
                Button("Add Follow-Up", action: commitFollowUp)
                    .buttonStyle(.glassProminent)
                    .disabled(followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .transition(.opacity.calmed)
    }

    // MARK: Progress and the end

    /// How much is reviewed, as a hairline along the card's top that fills.
    private var progress: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.teal.opacity(0.7))
                .frame(width: max(0, proxy.size.width * review.reviewedFraction), height: 2)
                .animation(DS.Motion.smooth, value: review.reviewedFraction)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    private var finished: some View {
        let outcomes = review.outcomes
        let followUps = review.unsentFollowUps.count
        let summary = [outcomes.accepted > 0 ? "\(outcomes.accepted) accepted" : nil,
                       outcomes.followedUp > 0 ? "\(outcomes.followedUp) followed up" : nil].compactMap { $0 }.joined(separator: " · ")
        let target = model.send.lastTarget.map { AgentChip.parts($0.label).agent }
        let detail = followUps > 0 ? "\(summary). Your follow-ups go to \(target ?? "the agent") when you send them." : summary
        return HStack(spacing: DS.Space.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("All reviewed").font(.callout.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DS.Space.s)
            HStack(spacing: DS.Space.s) {
                Button("Back") { review.previous() }
                    .help("Look at the last note again")
                if followUps > 0 {
                    Button("Done") { review.end() }
                    Button(followUps == 1 ? "Send Follow-Up" : "Send \(followUps) Follow-Ups") { Task { await review.sendFollowUps() } }
                        .buttonStyle(.glassProminent)
                        .disabled(!model.send.isTargetAvailable || model.send.isSending || review.isSending)
                        .help(model.send.lastTarget.map { "Send the follow-ups you wrote to \($0.label)" } ?? "Choose an agent to send to")
                } else {
                    Button("Done") { review.end() }
                        .buttonStyle(.glassProminent)
                }
            }
            .controlSize(.small)
        }
        .transition(.opacity.calmed)
    }

    private func commitFollowUp() {
        let text = followUpText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await review.followUp(text) {
                followUpText = ""
                followUpFailed = false
                composing = false
            } else {
                followUpFailed = true
            }
        }
    }

    private func cancelFollowUp() {
        composing = false
        followUpText = ""
        followUpFailed = false
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
