import Core
import Foundation
import Remote
import Testing
@testable import Transports

struct HookInstallerTests {
    @Test func readsTheCodexMCPRegistration() {
        let toml = "model = \"x\"\n\n[mcp_servers.gloss]\nurl = \"http://127.0.0.1:47831/mcp?host=asus\"\n\n[mcp_servers.other]\nurl = \"http://o\"\n"
        #expect(HookInstaller.codexMCPURL(in: toml) == "http://127.0.0.1:47831/mcp?host=asus")
        #expect(HookInstaller.codexMCPURL(in: "[mcp_servers.\"gloss\"]\nurl='http://a/mcp'\n") == "http://a/mcp")
        #expect(HookInstaller.codexMCPURL(in: "[mcp_servers.other]\nurl = \"http://o\"\n") == nil)
        #expect(HookInstaller.codexMCPURL(in: "[mcp_servers.gloss] # ours\nurl_note = \"x\"\nurl = \"http://a/mcp\" # comment\n") == "http://a/mcp", "comments and look-alike keys")
    }

    /// Status follows the agent's own MCP registration: none is "not set up", another url is outdated.
    @Test func statusFollowsTheMCPRegistration() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcpurl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let installer = HookInstaller(fileSystem: LocalFileSystem(deleteBehavior: .permanent), home: home, hostAlias: "asus", port: 47831) { _ in
            ExecResult(exitStatus: 0, stdout: Data(), stderr: Data())
        }
        #expect(await installer.status(.claude) == .notInstalled)
        try #"{"mcpServers":{"gloss":{"type":"http","url":"http://127.0.0.1:47831/mcp"}}}"#.write(toFile: "\(home)/.claude.json", atomically: true, encoding: .utf8)
        #expect(await installer.status(.claude) == .outdated("MCP url differs"), "registered before urls carried the host")
        try #"{"mcpServers":{"gloss":{"type":"http","url":"http://127.0.0.1:47831/mcp?host=asus"}}}"#.write(toFile: "\(home)/.claude.json", atomically: true, encoding: .utf8)
        #expect(await installer.status(.claude) == .installed)
    }

    static let sampleSettings = """
    {"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"'/opt/homebrew/opt/moshi-hook/bin/moshi-hook' claude-hook","async":true}]}],"SessionStart":[{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/herdr-agent-state.sh"}]}]},"permissions":{"allow":["Bash(ls *)"]},"model":"opus"}
    """

    static let legacyCommand = "\"$HOME/.claude/hooks/gloss-notes.sh\" claude"

    /// The old prompt hook comes out; every other hook and value stays, and a group shared with the user's own
    /// handler keeps theirs.
    @Test func removesTheOldHookAndPreservesEveryOtherValue() throws {
        let withHook = Data(#"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"'/opt/homebrew/opt/moshi-hook/bin/moshi-hook' claude-hook","async":true}]},{"hooks":[{"type":"command","command":"\"$HOME/.claude/hooks/gloss-notes.sh\" claude","timeout":10}]}],"SessionStart":[{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/herdr-agent-state.sh"}]}]},"permissions":{"allow":["Bash(ls *)"]},"model":"opus"}"#.utf8)
        #expect(HookInstaller.hasLegacyEntry(in: withHook) && !HookInstaller.hasLegacyEntry(in: Data(Self.sampleSettings.utf8)))
        let cleaned = try HookInstaller.removingLegacyEntry(from: withHook)
        #expect(!HookInstaller.hasLegacyEntry(in: cleaned))
        let object = try #require(try JSONSerialization.jsonObject(with: cleaned) as? [String: Any])
        let submit = try #require((object["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])
        #expect(submit.count == 1 && (submit[0]["hooks"] as? [[String: Any]])?.first?["async"] as? Bool == true)
        #expect(((object["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.count == 1)
        #expect((object["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls *)"] && object["model"] as? String == "opus")

        let shared = Data(#"{"hooks":{"UserPromptSubmit":[{"matcher":"x","hooks":[{"type":"command","command":"other"},{"type":"command","command":"GLOSS_HOST='asus' \"$HOME/.claude/hooks/gloss-notes.sh\" claude"}]}]}}"#.utf8)
        let sharedCleaned = try #require(((try JSONSerialization.jsonObject(with: try HookInstaller.removingLegacyEntry(from: shared)) as? [String: Any])?["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])
        #expect(sharedCleaned.count == 1 && (sharedCleaned[0]["hooks"] as? [[String: Any]])?.map { $0["command"] as? String } == ["other"] && sharedCleaned[0]["matcher"] as? String == "x")

        let alone = Data(#"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$HOME/.claude/hooks/gloss-notes.sh\" codex"}]}]}}"#.utf8)
        #expect((try JSONSerialization.jsonObject(with: try HookInstaller.removingLegacyEntry(from: alone)) as? [String: Any])?.isEmpty == true, "empty structures go")
        #expect(throws: HookInstallerError.self) { try HookInstaller.removingLegacyEntry(from: Data("{not json".utf8)) }
    }

    @Test func mergesOpenCodeConfig() throws {
        let original = Data(#"{"$schema":"https://opencode.ai/config.json","provider":{"x":{"name":"X"}},"mcp":{"other":{"type":"local","command":["x"]}}}"#.utf8)
        let merged = try HookInstaller.mergeOpenCode(into: original, url: "http://127.0.0.1:47831/mcp")
        let object = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let mcp = try #require(object["mcp"] as? [String: Any])
        #expect((mcp["gloss"] as? [String: Any])?["url"] as? String == "http://127.0.0.1:47831/mcp")
        #expect((mcp["gloss"] as? [String: Any])?["enabled"] as? Bool == true && (mcp["other"] as? [String: Any])?["type"] as? String == "local")
        #expect((object["provider"] as? [String: Any])?.keys.contains("x") == true && object["$schema"] as? String == "https://opencode.ai/config.json")
        let removed = try HookInstaller.mergeOpenCode(into: merged, url: nil)
        let removedObject = try JSONSerialization.jsonObject(with: removed) as? [String: Any]
        #expect((removedObject?["mcp"] as? [String: Any])?.keys.sorted() == ["other"])
    }

    /// Uninstalling where nothing was installed creates no files and rewrites none.
    @Test func uninstallLeavesMissingAndForeignFilesAlone() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let foreign = "{\"model\":   \"opus\"}"
        try foreign.write(toFile: "\(home)/.claude/settings.json", atomically: true, encoding: .utf8)
        let installer = HookInstaller(fileSystem: LocalFileSystem(deleteBehavior: .permanent), home: home, port: 47831) { _ in
            ExecResult(exitStatus: 0, stdout: Data(), stderr: Data())
        }
        for agent in [HookAgent.claude, .codex, .opencode] {
            _ = try await installer.uninstall(agent)
        }
        #expect(try String(contentsOfFile: "\(home)/.claude/settings.json", encoding: .utf8) == foreign, "not reformatted")
        #expect(!FileManager.default.fileExists(atPath: installer.codexHooksPath))
        #expect(!FileManager.default.fileExists(atPath: installer.opencodeConfigPath))
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(home)/.claude") == ["settings.json"], "no backup of an untouched file")
    }

    /// Install into a temporary HOME registers MCP only; a machine with the old prompt hook shows Update, and
    /// installing (or removing) takes the hook, its script and an unused port file out, backing up the settings.
    @Test func installRegistersMCPAndRemovesTheOldHook() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: "\(home)/.claude/hooks", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(home)/.codex", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(home)/.config/gloss", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        // What an older build left behind.
        let legacySettings = try HookInstallerTests.settings(withLegacyHook: true)
        try legacySettings.write(to: URL(fileURLWithPath: "\(home)/.claude/settings.json"))
        try #"{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$HOME/.claude/hooks/gloss-notes.sh\" codex"}]}]}}"#.write(toFile: "\(home)/.codex/hooks.json", atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(toFile: "\(home)/.claude/hooks/gloss-notes.sh", atomically: true, encoding: .utf8)
        try "47831\n".write(toFile: "\(home)/.config/gloss/mcp-port", atomically: true, encoding: .utf8)
        let commands = CommandLog()
        let installer = HookInstaller(fileSystem: LocalFileSystem(deleteBehavior: .permanent), home: home, port: 47831) { line in
            await commands.record(line)
            return ExecResult(exitStatus: line.contains("remove") ? 1 : 0, stdout: Data(), stderr: Data())
        }
        #expect(await installer.status(.claude) == .outdated(HookInstaller.legacyHookReason))
        #expect(await installer.status(.codex) == .outdated(HookInstaller.legacyHookReason))

        let claude = try await installer.install(.claude)
        #expect(await commands.lines.contains("claude mcp add -s user --transport http gloss http://127.0.0.1:47831/mcp"))
        #expect(claude.notices.isEmpty)
        #expect(claude.backups.count == 1 && (try? Data(contentsOf: URL(fileURLWithPath: claude.backups[0]))) == legacySettings, "the backup is the original bytes")
        let settings = try Data(contentsOf: URL(fileURLWithPath: installer.claudeSettingsPath))
        #expect(!HookInstaller.hasLegacyEntry(in: settings))
        #expect((try JSONSerialization.jsonObject(with: settings) as? [String: Any])?["model"] as? String == "opus")
        #expect(FileManager.default.fileExists(atPath: installer.legacyScriptPath), "Codex still runs the old script until it is updated")
        // The agent CLI was stubbed, so write the registration it would have made.
        try #"{"mcpServers":{"gloss":{"type":"http","url":"http://127.0.0.1:47831/mcp"}}}"#.write(toFile: "\(home)/.claude.json", atomically: true, encoding: .utf8)
        #expect(await installer.status(.claude) == .installed)

        let codex = try await installer.install(.codex)
        #expect(codex.notices.isEmpty, "no hooks to trust any more")
        #expect(await commands.lines.contains("codex mcp add gloss --url http://127.0.0.1:47831/mcp"))
        #expect(!FileManager.default.fileExists(atPath: installer.legacyScriptPath), "no settings run it now")
        #expect(!FileManager.default.fileExists(atPath: installer.remotePortFilePath), "nothing reads the port file without the plugin")
        #expect(!HookInstaller.hasLegacyEntry(in: try Data(contentsOf: URL(fileURLWithPath: installer.codexHooksPath))))
        #expect(await installer.status(.codex) == .notInstalled, "stubbed CLI: no registration in config.toml")

        // A second install touches no file.
        let again = try await installer.install(.claude)
        #expect(again.changedFiles.isEmpty && again.backups.isEmpty)

        _ = try await installer.uninstall(.claude)
        #expect(await commands.lines.contains("claude mcp remove -s user gloss >/dev/null 2>&1"))
        let final = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: installer.claudeSettingsPath))) as? [String: Any])
        #expect(((final["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])?.count == 1 && final["model"] as? String == "opus")
    }

    static func settings(withLegacyHook: Bool) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(sampleSettings.utf8)) as? [String: Any])
        if withLegacyHook {
            var hooks = object["hooks"] as? [String: Any] ?? [:]
            var submit = hooks["UserPromptSubmit"] as? [Any] ?? []
            submit.append(["hooks": [["type": "command", "command": legacyCommand, "timeout": 10]]])
            hooks["UserPromptSubmit"] = submit
            object["hooks"] = hooks
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

actor CommandLog {
    private(set) var lines: [String] = []
    func record(_ line: String) { lines.append(line) }
}
