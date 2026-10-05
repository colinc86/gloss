import Testing
@testable import Core

struct TransportKindTests {
    /// A drain through /hook/<flavour> is recorded as the hook that asked, so the send history says which agent read it.
    @Test func hookFlavoursMapToTheirTransport() {
        #expect(TransportKind.hook(flavour: "claude") == .claudeHook)
        #expect(TransportKind.hook(flavour: "codex") == .codexHook)
        #expect(TransportKind.hook(flavour: "text") == .promptHook)
        #expect(TransportKind.promptHook.rawValue == "prompt-hook" && TransportKind.promptHook.displayName == "Prompt hook")
    }
}
