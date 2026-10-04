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

    /// A remote install registered before URLs carried the host shows as outdated, so Settings offers a reinstall.
    @Test func aRemoteRegistrationWithoutTheHostIsOutdated() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcpurl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let installer = HookInstaller(fileSystem: LocalFileSystem(deleteBehavior: .permanent), home: home, hostAlias: "asus", port: 47831) { _ in
            ExecResult(exitStatus: 0, stdout: Data(), stderr: Data())
        }
        _ = try await installer.install(.claude)
        #expect(await installer.status(.claude) == .installed, "no ~/.claude.json entry yet: nothing to compare")
        try #"{"mcpServers":{"gloss":{"type":"http","url":"http://127.0.0.1:47831/mcp"}}}"#.write(toFile: "\(home)/.claude.json", atomically: true, encoding: .utf8)
        #expect(await installer.status(.claude) == .outdated("MCP url differs"))
        try #"{"mcpServers":{"gloss":{"type":"http","url":"http://127.0.0.1:47831/mcp?host=asus"}}}"#.write(toFile: "\(home)/.claude.json", atomically: true, encoding: .utf8)
        #expect(await installer.status(.claude) == .installed)
    }

    static let sampleSettings = """
    {"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"'/opt/homebrew/opt/moshi-hook/bin/moshi-hook' claude-hook","async":true}]}],"SessionStart":[{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/herdr-agent-state.sh"}]}]},"permissions":{"allow":["Bash(ls *)"]},"model":"opus"}
    """

    @Test func mergesOurEntryOnceAndPreservesEveryOtherValue() throws {
        let command = "\"$HOME/.claude/hooks/gloss-notes.sh\" claude"
        let once = try HookInstaller.mergeHookEntry(into: Data(Self.sampleSettings.utf8), command: command)
        let twice = try HookInstaller.mergeHookEntry(into: once, command: command)
        #expect(once == twice, "a second install changes nothing")
        let object = try #require(try JSONSerialization.jsonObject(with: twice) as? [String: Any])
        let submit = try #require((object["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])
        #expect(submit.count == 2)
        #expect((submit[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "'/opt/homebrew/opt/moshi-hook/bin/moshi-hook' claude-hook")
        #expect((submit[0]["hooks"] as? [[String: Any]])?.first?["async"] as? Bool == true)
        #expect((submit[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String == command)
        #expect((submit[1]["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 10)
        #expect(((object["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.count == 1)
        #expect((object["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls *)"] && object["model"] as? String == "opus")
        #expect(HookInstaller.hasOurEntry(in: twice) && !HookInstaller.hasOurEntry(in: Data(Self.sampleSettings.utf8)))

        // A changed command replaces ours instead of adding a second entry.
        let moved = try HookInstaller.mergeHookEntry(into: twice, command: "GLOSS_HOST='asus' " + command)
        let movedObject = try JSONSerialization.jsonObject(with: moved) as? [String: Any]
        let movedSubmit = try #require((movedObject?["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])
        #expect(movedSubmit.count == 2 && HookInstaller.hasEntry(in: moved, command: "GLOSS_HOST='asus' " + command))

        // Our handler inside a user's own group leaves the rest of that group alone.
        let shared = Data(#"{"hooks":{"UserPromptSubmit":[{"matcher":"x","hooks":[{"type":"command","command":"other"},{"type":"command","command":"\"$HOME/.claude/hooks/gloss-notes.sh\" claude"}]}]}}"#.utf8)
        let sharedMerged = try HookInstaller.mergeHookEntry(into: shared, command: command)
        let sharedSubmit = try #require(((try JSONSerialization.jsonObject(with: sharedMerged) as? [String: Any])?["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])
        #expect(sharedSubmit.count == 2 && (sharedSubmit[0]["hooks"] as? [[String: Any]])?.map { $0["command"] as? String } == ["other"] && sharedSubmit[0]["matcher"] as? String == "x")

        let removed = try HookInstaller.mergeHookEntry(into: moved, command: nil)
        #expect(!HookInstaller.hasOurEntry(in: removed))
        let removedObject = try #require(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
        #expect(((removedObject["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])?.count == 1)

        // Empty and missing structures.
        let fresh = try HookInstaller.mergeHookEntry(into: Data("{}".utf8), command: command)
        #expect(HookInstaller.hasOurEntry(in: fresh))
        let emptied = try HookInstaller.mergeHookEntry(into: fresh, command: nil)
        let emptiedObject = try JSONSerialization.jsonObject(with: emptied) as? [String: Any]
        #expect(emptiedObject?.isEmpty == true)
        #expect(throws: HookInstallerError.self) { try HookInstaller.mergeHookEntry(into: Data("{not json".utf8), command: command) }
    }

    @Test func editsCodexFeaturesWithoutTouchingOtherLines() {
        let base = "model = \"gpt-5\"\n\n[features]\ndaemon_auto_start = false\nhooks = true\n\n[hooks.state]\nx = 1\n"
        #expect(HookInstaller.enableCodexHooks(in: base) == base, "already enabled: untouched")
        let disabled = base.replacingOccurrences(of: "hooks = true", with: "hooks = false")
        #expect(HookInstaller.enableCodexHooks(in: disabled) == base)
        let missingKey = "model = \"gpt-5\"\n\n[features]\ndaemon_auto_start = false\n\n[hooks.state]\nx = 1\n"
        #expect(HookInstaller.enableCodexHooks(in: missingKey) == "model = \"gpt-5\"\n\n[features]\nhooks = true\ndaemon_auto_start = false\n\n[hooks.state]\nx = 1\n")
        #expect(HookInstaller.enableCodexHooks(in: "model = \"gpt-5\"\n") == "model = \"gpt-5\"\n\n[features]\nhooks = true\n")
        #expect(HookInstaller.enableCodexHooks(in: "") == "[features]\nhooks = true\n")
        let crlf = "model = \"x\"\r\n\r\n[features]\r\nhooks = true # keep\r\n"
        #expect(HookInstaller.enableCodexHooks(in: crlf) == crlf, "CRLF files and trailing comments are recognised")
        #expect(HookInstaller.enableCodexHooks(in: "[features]\r\nhooks = false\r\n") == "[features]\r\nhooks = true\r\n")
        #expect(HookInstaller.codexHooksEnabled(base) && !HookInstaller.codexHooksEnabled(disabled))
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

    /// Full install into a temporary HOME: script copied with mode 755, settings merged with a backup, MCP registration
    /// recorded through the runner, Codex features enabled, status reported, uninstall reverses it all.
    @Test func installsAndUninstallsInATemporaryHome() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: "\(home)/.claude", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(home)/.codex", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Self.sampleSettings.write(toFile: "\(home)/.claude/settings.json", atomically: true, encoding: .utf8)
        try "model = \"gpt-5\"\n\n[features]\nhooks = false\n".write(toFile: "\(home)/.codex/config.toml", atomically: true, encoding: .utf8)
        let commands = CommandLog()
        let installer = HookInstaller(fileSystem: LocalFileSystem(deleteBehavior: .permanent), home: home, port: 47831) { line in
            await commands.record(line)
            return ExecResult(exitStatus: line.contains("remove") ? 1 : 0, stdout: Data(), stderr: Data())
        }

        let claude = try await installer.install(.claude)
        #expect(claude.changedFiles.contains(installer.scriptPath) && claude.changedFiles.contains(installer.claudeSettingsPath))
        #expect(claude.backups.count == 1 && FileManager.default.fileExists(atPath: claude.backups[0]))
        let backupBytes = try Data(contentsOf: URL(fileURLWithPath: claude.backups[0]))
        #expect(backupBytes == Data(Self.sampleSettings.utf8), "the backup is the original bytes")
        let mode = try FileManager.default.attributesOfItem(atPath: installer.scriptPath)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        let installedScript = try Data(contentsOf: URL(fileURLWithPath: installer.scriptPath))
        let bundledScript = try HookInstaller.bundledScript()
        #expect(installedScript == bundledScript)
        #expect(await commands.lines.contains("claude mcp add -s user --transport http gloss http://127.0.0.1:47831/mcp"))
        #expect(claude.notices.isEmpty)
        #expect(await installer.status(.claude) == .installed)
        #expect(await installer.status(.codex) == .notInstalled)

        let codex = try await installer.install(.codex)
        let codexConfig = try String(contentsOfFile: installer.codexConfigPath, encoding: .utf8)
        #expect(codexConfig == "model = \"gpt-5\"\n\n[features]\nhooks = true\n")
        let codexHooks = try Data(contentsOf: URL(fileURLWithPath: installer.codexHooksPath))
        #expect(HookInstaller.hasOurEntry(in: codexHooks))
        #expect(codex.notices.contains { $0.contains("/hooks") })
        #expect(await installer.status(.codex) == .installed)
        #expect(await commands.lines.contains("codex mcp add gloss --url http://127.0.0.1:47831/mcp"))

        // A tampered script shows as outdated.
        try "#!/bin/sh\n".write(toFile: installer.scriptPath, atomically: true, encoding: .utf8)
        #expect(await installer.status(.claude) == .outdated("hook script differs from this build"))
        _ = try await installer.install(.claude)
        #expect(await installer.status(.claude) == .installed)

        // Backups are pruned to three per file.
        for _ in 0..<5 {
            _ = try await installer.uninstall(.claude)
            _ = try await installer.install(.claude)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: "\(home)/.claude").filter { $0.hasPrefix("settings.json.gloss-backup-") }
        #expect(backups.count <= 3)

        _ = try await installer.uninstall(.claude)
        #expect(await installer.status(.claude) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: installer.scriptPath), "codex still uses the script")
        _ = try await installer.uninstall(.codex)
        #expect(!FileManager.default.fileExists(atPath: installer.scriptPath))
        let final = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: installer.claudeSettingsPath))) as? [String: Any])
        #expect(((final["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]])?.count == 1 && final["model"] as? String == "opus")

        // Remote flavour: GLOSS_HOST in the command and a port file the script can find.
        let token = String(repeating: "cd", count: 32)
        let remote = HookInstaller(fileSystem: LocalFileSystem(deleteBehavior: .permanent), home: home, hostAlias: "asus", port: 47831, token: token) { _ in ExecResult(exitStatus: 0, stdout: Data(), stderr: Data()) }
        let report = try await remote.install(.claude)
        #expect(report.changedFiles.contains(remote.remotePortFilePath))
        let portFile = try String(contentsOfFile: remote.remotePortFilePath, encoding: .utf8)
        #expect(portFile == "47831\n\(token)\n", "the port, then the token the hook sends")
        let portMode = try FileManager.default.attributesOfItem(atPath: remote.remotePortFilePath)[.posixPermissions] as? Int
        #expect(portMode == 0o600, "other users on the host cannot read the token")
        #expect(remote.mcpURL == "http://127.0.0.1:47831/mcp?host=asus&token=\(token)")
        let remoteSettings = try Data(contentsOf: URL(fileURLWithPath: remote.claudeSettingsPath))
        #expect(HookInstaller.hasEntry(in: remoteSettings, command: "GLOSS_HOST='asus' \"$HOME/.claude/hooks/gloss-notes.sh\" claude"))
    }

    /// The real script against a real server: prints the hook JSON when notes are pending, nothing otherwise.
    @Test func scriptTalksToTheServer() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: "\(home)/Library/Application Support/Gloss", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let (store, _) = try await MCPServerTests.makeStore(count: 2, attachmentDirectory: home)
        // A token, as the app runs: the script reads it from the port file's second line.
        let server = MCPServer(dependencies: MCPServerTests.dependencies(store: store), port: 0, portFileURL: URL(fileURLWithPath: "\(home)/Library/Application Support/Gloss/mcp-port"), token: String(repeating: "ab", count: 32))
        try await server.start()
        defer { Task { await server.stop() } }
        let portFileMode = try FileManager.default.attributesOfItem(atPath: "\(home)/Library/Application Support/Gloss/mcp-port")[.posixPermissions] as? Int
        #expect(portFileMode == 0o600, "the port file holds the token")
        let script = try #require(Bundle.module.url(forResource: "gloss-notes", withExtension: "sh", subdirectory: "HookScripts")?.path)

        func runScript(flavour: String, cwd: String, home: String) -> (Int32, String, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script, flavour]
            process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try? process.run()
            input.fileHandleForWriting.write(Data("{\"session_id\":\"s\",\"cwd\":\"\(cwd)\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}".utf8))
            try? input.fileHandleForWriting.close()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }

        let (status, out, err) = runScript(flavour: "claude", cwd: "/tmp/demo", home: home)
        #expect(status == 0 && err.isEmpty)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let context = ((json["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String) ?? ""
        #expect(context.contains("File: /tmp/demo/README.md") && context.count <= 10_000)

        let (status2, out2, err2) = runScript(flavour: "codex", cwd: "/elsewhere", home: home)
        #expect(status2 == 0 && out2.isEmpty && err2.isEmpty, "nothing pending under that cwd: silent")
        let (status3, out3, err3) = runScript(flavour: "claude", cwd: "/tmp/demo", home: "/nonexistent")
        #expect(status3 == 0 && out3.isEmpty && err3.isEmpty, "no port file: silent")
        await server.stop()
        let (status4, out4, _) = runScript(flavour: "claude", cwd: "/tmp/demo", home: home)
        #expect(status4 == 0 && out4.isEmpty, "server down: silent")
    }
}

actor CommandLog {
    private(set) var lines: [String] = []
    func record(_ line: String) { lines.append(line) }
}
