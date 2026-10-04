import SwiftUI

/// What the agent said when it resolved a note, drawn as its turn in a conversation: a tinted bubble whose tail points
/// up at the comment it answers, with who spoke and how. A question is orange and asks for you; a finished note's
/// reply is quiet. Messages app and Linear's agent replies read this way: the voice is clear before the words are.
struct AgentMessageBubble: View {
    let message: String
    let needsInput: Bool
    /// The agent the note was last sent to, when there was a send; otherwise "Agent".
    let agent: String?

    private var tint: Color { needsInput ? .orange : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Label {
                Text(Self.heading(agent: agent, needsInput: needsInput))
            } icon: {
                Image(systemName: needsInput ? "questionmark.bubble.fill" : "checkmark.bubble.fill")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .foregroundStyle(needsInput ? .primary : .secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.top, DS.Space.s + BubbleShape.tail)
        .padding(.bottom, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(needsInput ? 0.12 : 0.08), in: BubbleShape())
        .overlay(BubbleShape().stroke(tint.opacity(needsInput ? 0.28 : 0.12), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .help("What the agent said when it resolved this note")
    }

    nonisolated static func heading(agent: String?, needsInput: Bool) -> String {
        let name = agent?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Agent"
        return needsInput ? "\(name) asks" : "\(name) replied"
    }
}

/// A rounded rectangle with a small tail at the top leading edge, pointing up at what it answers. One continuous
/// outline, so a stroke runs around the tail without a seam across its base.
nonisolated struct BubbleShape: Shape {
    static let tail: CGFloat = 6
    var radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + Self.tail
        let r = min(radius, (rect.height - Self.tail) / 2, rect.width / 2)
        let tailStart = rect.minX + r + 6
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top + r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.minX + r, y: top), radius: r)
        path.addLine(to: CGPoint(x: tailStart, y: top))
        path.addQuadCurve(to: CGPoint(x: tailStart + 6, y: rect.minY), control: CGPoint(x: tailStart + 4, y: top))
        path.addQuadCurve(to: CGPoint(x: tailStart + 12, y: top), control: CGPoint(x: tailStart + 8, y: top))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: top), radius: r)
        path.closeSubpath()
        return path
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview {
    VStack(spacing: 12) {
        AgentMessageBubble(message: "Should it be shorter, or just plainer?", needsInput: true, agent: "claude")
        AgentMessageBubble(message: "Moved the helper to Utilities and renamed it.", needsInput: false, agent: nil)
    }
    .padding()
    .frame(width: 300)
}
