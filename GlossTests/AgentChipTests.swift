import Testing
@testable import Gloss

/// How the target chip splits an agent label into its parts.
@MainActor
struct AgentChipTests {
    @Test func splitsAgentTitleAndPane() {
        let herdr = AgentChip.parts("claude · Reorganize breadboard layout (w5:p1)")
        #expect(herdr.agent == "claude" && herdr.title == "Reorganize breadboard layout" && herdr.pane == "w5:p1")
        let dotted = AgentChip.parts("claude · fix · the parser (w1:p2)")
        #expect(dotted.title == "fix · the parser", "only the first separator splits off the agent")
        let tmux = AgentChip.parts("Main:1.1 · zsh")
        #expect(tmux.agent == "Main:1.1" && tmux.title == "zsh" && tmux.pane == nil)
        let bare = AgentChip.parts("Claude Code hook")
        #expect(bare.agent == "Claude Code hook" && bare.title == nil && bare.pane == nil)
    }
}
