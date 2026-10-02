import Core
import Foundation
import Remote
import Testing
@testable import Transports

struct RemoteInstallTests {
    /// `GLOSS_REMOTE_HOST=<alias>`: installs the hook, the Codex entry, and the Herdr plugin into a temporary home on
    /// the host over SFTP and exec. Only `herdr plugin link/unlink/list` run for real there (and are undone);
    /// the agents' `mcp add` commands are answered by a stub so the host's real agent configs are never touched.
    @Test(.enabled(if: TestGates.remoteHost != nil))
    func installsHooksAndPluginIntoATemporaryRemoteHome() async throws {
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
            _ = try await fileSystem.writeAtomically(Data(#"{"permissions":{"allow":["Bash(ls *)"]}}"#.utf8), to: PathUtilities.join(home, ".claude/settings.json"), preservingModeFrom: nil)
            let claude = try await installer.install(.claude)
            #expect(claude.changedFiles.contains(installer.scriptPath) && claude.changedFiles.contains(installer.remotePortFilePath))
            let settings = try await fileSystem.read(installer.claudeSettingsPath)
            #expect(HookInstaller.hasEntry(in: settings, command: "GLOSS_HOST='\(alias)' \"$HOME/.claude/hooks/gloss-notes.sh\" claude"))
            #expect(((try JSONSerialization.jsonObject(with: settings) as? [String: Any])?["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls *)"])
            let mode = try await connection.exec("stat -c %a \(ShellQuote.single(installer.scriptPath)) 2>/dev/null || stat -f %Lp \(ShellQuote.single(installer.scriptPath))").stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(mode == "755")
            #expect(await installer.status(.claude) == .installed)

            // The script on the host finds the port file and stays silent when the forwarded server is absent.
            let probe = try await connection.exec("printf '{\"cwd\":\"/tmp\"}' | HOME=\(ShellQuote.single(home)) sh \(ShellQuote.single(installer.scriptPath)) claude; echo \"exit=$?\"")
            #expect(probe.stdoutText == "exit=0\n" && probe.stderrText.isEmpty, "\(probe.stdoutText) \(probe.stderrText)")

            let codex = try await installer.install(.codex)
            #expect(codex.notices.contains { $0.contains("/hooks") })
            #expect(await installer.status(.codex) == .installed)

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
            #expect((try? await fileSystem.stat(installer.scriptPath)) == nil)
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
