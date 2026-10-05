import Core
import Foundation
import Remote
import Testing
@testable import Transports

struct RemoteInstallTests {
    /// `GLOSS_REMOTE_HOST=<alias>`: registers the agents and installs the Herdr plugin into a temporary home on the
    /// host over SFTP and exec, removing an old prompt hook left there. Only `herdr plugin link/unlink/list` run for real there (and are undone);
    /// the agents' `mcp add` commands are answered by a stub so the host's real agent configs are never touched.
    @Test(.enabled(if: TestGates.remoteHost != nil))
    func installsAgentsAndPluginIntoATemporaryRemoteHome() async throws {
        let alias = try #require(TestGates.remoteHost)
        let control = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: control, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: control) }
        let manager = SSHConnectionManager(controlDirectory: control)
        let hostID = HostID.new()
        let connection = try await manager.connection(for: hostID, alias: alias)
        let tools = try await connection.tools()
        let home = PathUtilities.join(tools.tmpdir, "gloss-home-\(UUID().uuidString.prefix(8))")
        let fileSystem = SFTPFileSystem(hostID: hostID, connection: connection)
        let commands = CommandLog()
        let installer = HookInstaller(fileSystem: fileSystem, home: home, hostAlias: alias, port: 47831) { line in
            await commands.record(line)
            if line.hasPrefix("herdr plugin"), tools.herdr {
                return try await connection.exec(LocalShell.pathPrefix + line, timeout: .seconds(30))
            }
            return ExecResult(exitStatus: 0, stdout: Data(), stderr: Data())
        }
        do {
            try await fileSystem.makeDirectory(PathUtilities.join(home, ".claude"))
            // What an older build left on the host: the prompt hook beside the user's own settings, and its script.
            let legacy = #"{"permissions":{"allow":["Bash(ls *)"]},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"GLOSS_HOST='x' \"$HOME/.claude/hooks/gloss-notes.sh\" claude"}]}]}}"#
            _ = try await fileSystem.writeAtomically(Data(legacy.utf8), to: installer.claudeSettingsPath, preservingModeFrom: nil)
            try await fileSystem.makeDirectory(PathUtilities.join(home, ".claude/hooks"))
            _ = try await fileSystem.writeAtomically(Data("#!/bin/sh\n".utf8), to: installer.legacyScriptPath, preservingModeFrom: nil)
            #expect(await installer.status(.claude) == .outdated(HookInstaller.legacyHookReason))
            let claude = try await installer.install(.claude)
            #expect(claude.changedFiles.contains(installer.claudeSettingsPath) && claude.changedFiles.contains(installer.legacyScriptPath))
            let settings = try await fileSystem.read(installer.claudeSettingsPath)
            #expect(!HookInstaller.hasLegacyEntry(in: settings))
            #expect(((try JSONSerialization.jsonObject(with: settings) as? [String: Any])?["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls *)"])
            #expect((try? await fileSystem.stat(installer.legacyScriptPath)) == nil)
            #expect(await commands.lines.contains { $0.hasPrefix("claude mcp add -s user --transport http gloss ") && $0.contains("host=\(alias)") })

            _ = try await installer.install(.codex)
            #expect(await commands.lines.contains { $0.hasPrefix("codex mcp add gloss --url ") })

            if tools.herdr {
                let before = try await connection.exec(LocalShell.pathPrefix + "herdr plugin list --json").stdoutText
                if !before.contains("\"plugin_id\":\"gloss\"") {
                    let plugin = try await installer.install(.herdrPlugin)
                    #expect(plugin.changedFiles.contains(installer.hostFilePath))
                    #expect(await installer.status(.herdrPlugin) == .installed)
                    let listed = try await connection.exec(LocalShell.pathPrefix + "herdr plugin action list").stdoutText
                    #expect(listed.contains("note-from-selection"))
                    _ = try await installer.uninstall(.herdrPlugin)
                    #expect(await installer.status(.herdrPlugin) == .notInstalled)
                    _ = try? await connection.exec("rm -rf -- \"$HOME/.local/state/herdr/plugins/gloss\" \"$HOME/.config/herdr/plugins/config/gloss\"")
                }
            }
            _ = try await installer.uninstall(.claude)
            _ = try await installer.uninstall(.codex)
            #expect(await installer.status(.claude) == .notInstalled)
        } catch {
            // Unlink first (it only needs exec), then remove the host's plugin dirs and the temporary home.
            _ = try? await installer.uninstall(.herdrPlugin)
            _ = try? await connection.exec("rm -rf -- \"$HOME/.local/state/herdr/plugins/gloss\" \"$HOME/.config/herdr/plugins/config/gloss\" \(ShellQuote.single(home))")
            await manager.disconnectAll()
            throw error
        }
        let removed = try await connection.exec("rm -rf -- \(ShellQuote.single(home)); test ! -e \(ShellQuote.single(home)) && echo gone")
        #expect(removed.stdoutText == "gone\n")
        await manager.disconnectAll()
        #expect(!(await connection.check()))
    }
}
