import Testing
@testable import Core

struct TransportKindTests {
    /// The prompt hooks are gone, but sends older builds recorded through them still read in the history.
    @Test func oldHookSendsStillDecode() {
        #expect(TransportKind(rawValue: "claude-hook") == .claudeHook && TransportKind(rawValue: "codex-hook") == .codexHook)
        #expect(TransportKind.promptHook.rawValue == "prompt-hook" && TransportKind.promptHook.displayName == "Prompt hook")
    }
}
