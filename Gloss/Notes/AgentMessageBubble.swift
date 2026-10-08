import SwiftUI

/// One of the agent's turns in a note's thread: a tinted bubble whose tail points up at what it answers, headed only by
/// who spoke; whether it asks or reports is in its words. The question still waiting on you is orange, which reading
/// can't tell; everything else is quiet. A collapsed card
/// cuts a long message at four lines and offers the rest with Show conversation.
struct AgentMessageBubble: View {
    let message: String
    /// The agent asked something.
    let asks: Bool
    /// …and is still waiting on the user's answer; only then is the bubble orange.
    var waiting = false
    /// The agent the note was last sent to, when there was a send; otherwise "Agent".
    let agent: String?
    var expanded = true
    /// Set when the collapsed bubble cuts the message short.
    var isCut: Binding<Bool> = .constant(false)

    private var needsInput: Bool { asks && waiting }
    private var tint: Color { needsInput ? .orange : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(Self.heading(agent: agent))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            TruncatingText(text: Text(message).font(.callout).foregroundStyle(needsInput ? .primary : .secondary),
                           lineLimit: 4, expanded: expanded, isCut: isCut)
                .textSelection(.enabled)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.top, DS.Space.s + BubbleShape.tail)
        .padding(.bottom, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(needsInput ? 0.12 : 0.08), in: BubbleShape())
        .overlay(BubbleShape().stroke(tint.opacity(needsInput ? 0.28 : 0.12), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(agent: agent, message: message, waiting: needsInput))
        .help(needsInput ? "Waiting for your answer" : "")
    }

    /// Who spoke: the agent by its own name ("Claude Code"), or "Agent" when it is unknown.
    nonisolated static func heading(agent: String?) -> String {
        displayName(agent?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Agent")
    }

    /// As VoiceOver reads it: the name, the words, and, for the question still open, that it waits on you.
    nonisolated static func spoken(agent: String?, message: String, waiting: Bool) -> String {
        "\(heading(agent: agent)): \(message)\(waiting ? ", waiting for your answer" : "")"
    }

    /// The agents by their own names; MCP records them as `claude`, `codex` and `opencode`. Any other client keeps
    /// the name it gave.
    nonisolated static func displayName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        default: agent
        }
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
        AgentMessageBubble(message: "Should it be shorter, or just plainer?", asks: true, waiting: true, agent: "claude")
        AgentMessageBubble(message: "Moved the helper to Utilities and renamed it.", asks: false, agent: nil)
    }
    .padding()
    .frame(width: 300)
}
