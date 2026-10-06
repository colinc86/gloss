import Core
import Foundation
import Remote
import Testing
import Transports
@testable import Gloss

/// Issue #10: an agent set-up that an update made outdated is noticed without opening Settings, and dismissing the
/// notice holds only until something else needs updating.
@MainActor
struct AgentsUpdateNoticeTests {
    @Test func anOldPromptHookRaisesTheNoticeUntilDismissed() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-notice-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let saved = UserDefaults.standard.string(forKey: "agents.updateNoticeDismissed")
        defer { UserDefaults.standard.set(saved, forKey: "agents.updateNoticeDismissed") }

        let hooks = HooksModel()
        hooks.dismissedSignature = nil
        hooks.installerProvider = { _ in
            HookInstaller(fileSystem: LocalFileSystem(deleteBehavior: .permanent), home: home, port: 47831) { _ in ExecResult(exitStatus: 0, stdout: Data(), stderr: Data()) }
        }
        await hooks.refresh(hosts: [.local], agents: HooksModel.launchCheckedAgents)
        #expect(hooks.needsUpdate.isEmpty && !hooks.showsUpdateNotice, "nothing installed: nothing to update")

        try #"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$HOME/.claude/hooks/gloss-notes.sh\" claude"}]}]}}"#
            .write(toFile: "\(home)/.claude/settings.json", atomically: true, encoding: .utf8)
        await hooks.refresh(hosts: [.local], agents: HooksModel.launchCheckedAgents)
        #expect(hooks.needsUpdate.map(\.key.agent) == [.claude])
        #expect(hooks.showsUpdateNotice)
        hooks.dismissUpdateNotice()
        #expect(!hooks.showsUpdateNotice, "dismissed")
        await hooks.refresh(hosts: [.local], agents: HooksModel.launchCheckedAgents)
        #expect(!hooks.showsUpdateNotice, "the same thing stays dismissed")

        // Something new needs updating: the notice comes back.
        try FileManager.default.createDirectory(atPath: "\(home)/.codex", withIntermediateDirectories: true)
        try #"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$HOME/.claude/hooks/gloss-notes.sh\" codex"}]}]}}"#
            .write(toFile: "\(home)/.codex/hooks.json", atomically: true, encoding: .utf8)
        await hooks.refresh(hosts: [.local], agents: HooksModel.launchCheckedAgents)
        #expect(hooks.needsUpdate.count == 2 && hooks.showsUpdateNotice)
    }
}
