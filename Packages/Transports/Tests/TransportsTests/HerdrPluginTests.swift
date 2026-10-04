import Core
import Foundation
import Remote
import Testing
@testable import Transports

struct HerdrPluginTests {
    @Test func bundleShipsAValidManifestAndScript() throws {
        let manifest = String(decoding: try HookInstaller.bundledPluginFile("herdr-plugin.toml"), as: UTF8.self)
        #expect(manifest.contains("id = \"gloss\"") && manifest.contains("platforms = [\"macos\", \"linux\"]"))
        #expect(manifest.contains("id = \"note-from-selection\"") && manifest.contains("id = \"open-link\"") && manifest.contains("[[link_handlers]]"))
        let script = String(decoding: try HookInstaller.bundledPluginFile("bin/gloss-plugin.sh"), as: UTF8.self)
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(HookInstaller.keybindingSnippet.contains("gloss.note-from-selection"))
    }

    /// The script in dry-run mode: URLs on this Mac, JSON for the HTTP route, silence without a selection.
    @Test func scriptBuildsURLsAndBodies() throws {
        let root = try #require(Bundle.module.url(forResource: "HerdrPlugin", withExtension: nil)?.path)
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-plugin-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: "\(home)/.config/gloss", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        func run(_ mode: String, context: String, env: [String: String] = [:]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["bin/gloss-plugin.sh", mode]
            process.currentDirectoryURL = URL(fileURLWithPath: root)
            process.environment = ["HOME": home, "PATH": "/usr/bin:/bin", "HERDR_PLUGIN_CONTEXT_JSON": context, "GLOSS_PLUGIN_DRY_RUN": "1"].merging(env) { _, new in new }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        #expect(run("note", context: #"{"focused_pane_cwd":"/tmp/x y","focused_pane_id":"w1:p1","focused_pane_agent":"claude","selected_text":"hello & bye"}"#)
            == "gloss://note?host=local&cwd=%2Ftmp%2Fx%20y&pane=w1%3Ap1&agent=claude&text=hello%20%26%20bye")
        #expect(run("open", context: #"{"focused_pane_cwd":"/tmp/x","clicked_url":"file:///tmp/a%20b.md"}"#) == "gloss://open?host=local&path=%2Ftmp%2Fa%20b.md")
        #expect(run("open", context: #"{"focused_pane_cwd":"/tmp/x","selected_text":"docs/plan.md"}"#) == "gloss://open?host=local&path=%2Ftmp%2Fx%2Fdocs%2Fplan.md")
        #expect(run("open", context: #"{"focused_pane_cwd":"/tmp/x","selected_text":"Sources/App.swift:42:7"}"#) == "gloss://open?host=local&path=%2Ftmp%2Fx%2FSources%2FApp.swift&line=42")
        #expect(run("open", context: #"{"focused_pane_cwd":"/tmp/x","selected_text":"/srv/log.txt:9"}"#) == "gloss://open?host=local&path=%2Fsrv%2Flog.txt&line=9")
        #expect(run("open", context: #"{"focused_pane_cwd":"/tmp/x","selected_text":"/srv/file2:10"}"#) == "gloss://open?host=local&path=%2Fsrv%2Ffile2&line=10")
        #expect(run("open", context: #"{"focused_pane_cwd":"/tmp/x","clicked_url":"file:///tmp/a.md#L12"}"#) == "gloss://open?host=local&path=%2Ftmp%2Fa.md&line=12")
        #expect(run("open", context: #"{"focused_pane_cwd":"/tmp/x","selected_text":"/srv/12:30"}"#) == "gloss://open?host=local&path=%2Fsrv%2F12%3A30", "a digits-only name in a directory keeps its colons too")
        #expect(run("open", context: #"{"focused_pane_cwd":"/tmp/x","selected_text":"12:30"}"#) == "gloss://open?host=local&path=%2Ftmp%2Fx%2F12%3A30", "a name made only of digits keeps its colons")
        #expect(run("note", context: #"{"focused_pane_cwd":"/tmp/x"}"#).isEmpty, "no selection: nothing to send")
        let long = String(repeating: "y", count: 7000)
        let longURL = run("note", context: "{\"focused_pane_cwd\":\"/tmp/x\",\"selected_text\":\"\(long)\"}")
        #expect(longURL.contains("&file=") && longURL.contains("Gloss%2Finbox%2Fselection-"), "long selections go through the app's inbox: \(longURL.prefix(160))")
        #expect(run("open", context: #"{"focused_pane_cwd":"/tmp/x","clicked_url":"file:///srv/app.log"}"#, env: ["GLOSS_PLUGIN_TRANSPORT": "http"]).isEmpty, "no port file: silent")
        try "47831\n".write(toFile: "\(home)/.config/gloss/mcp-port", atomically: true, encoding: .utf8)
        try "asus\n".write(toFile: "\(home)/.config/gloss/host", atomically: true, encoding: .utf8)
        let openBody = run("open", context: #"{"focused_pane_cwd":"/tmp/x","clicked_url":"file:///srv/app.log"}"#, env: ["GLOSS_PLUGIN_TRANSPORT": "http"])
        #expect((try? JSONSerialization.jsonObject(with: Data(openBody.utf8)) as? [String: String]) == ["host": "asus", "path": "/srv/app.log"])
        let lineBody = run("open", context: #"{"focused_pane_cwd":"/srv","selected_text":"app.py:88"}"#, env: ["GLOSS_PLUGIN_TRANSPORT": "http"])
        let lineObject = try JSONSerialization.jsonObject(with: Data(lineBody.utf8)) as? [String: Any]
        #expect(lineObject?["path"] as? String == "/srv/app.py" && lineObject?["line"] as? Int == 88)
        let body = run("note", context: #"{"focused_pane_cwd":"/home/colin","selected_text":"line1\nline2 \"q\""}"#, env: ["GLOSS_PLUGIN_TRANSPORT": "http"])
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(object?["host"] as? String == "asus" && object?["cwd"] as? String == "/home/colin" && object?["text"] as? String == "line1\nline2 \"q\"")
        // The URL route needs no files under HOME; the host file is simply absent, so the note targets local.
        #expect(run("note", context: #"{"focused_pane_cwd":"/tmp/x","selected_text":"x"}"#, env: ["HOME": "/nonexistent"]).hasPrefix("gloss://note?host=local"))
        // With the app's token file, a note link carries the token (a web page's link could not).
        let tokenHome = NSTemporaryDirectory() + "gloss-token-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: tokenHome + "/Library/Application Support/Gloss", withIntermediateDirectories: true)
        try? "0123456789abcdef\n".write(toFile: tokenHome + "/Library/Application Support/Gloss/url-token", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tokenHome) }
        #expect(run("note", context: #"{"focused_pane_cwd":"/tmp/x","selected_text":"x"}"#, env: ["HOME": tokenHome]).hasSuffix("&token=0123456789abcdef"))
        #expect(run("note", context: #"{"focused_pane_cwd":"/tmp/x","selected_text":"x"}"#, env: ["HOME": "", "GLOSS_PLUGIN_TRANSPORT": "http"]).isEmpty)
    }

    @Test func installsThePluginWithAFakeHerdr() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-plugin-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let commands = CommandLog()
        let installer = HookInstaller(fileSystem: LocalFileSystem(deleteBehavior: .permanent), home: home, hostAlias: "asus", port: 47831) { line in
            await commands.record(line)
            if line.hasPrefix("herdr plugin list") { return ExecResult(exitStatus: 0, stdout: Data(#"{"result":{"plugins":[{"plugin_id":"gloss"}]}}"#.utf8), stderr: Data()) }
            return ExecResult(exitStatus: line.contains("unlink") ? 1 : 0, stdout: Data(), stderr: Data())
        }
        let report = try await installer.install(.herdrPlugin)
        #expect(report.changedFiles.contains(installer.hostFilePath) && report.changedFiles.contains("\(installer.pluginDirectory)/bin/gloss-plugin.sh"))
        #expect(try String(contentsOfFile: installer.hostFilePath, encoding: .utf8) == "asus\n")
        let mode = try FileManager.default.attributesOfItem(atPath: "\(installer.pluginDirectory)/bin/gloss-plugin.sh")[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(await commands.lines.contains("herdr plugin link '\(installer.pluginDirectory)'"))
        #expect(report.notices.contains { $0.contains("prefix+n") })
        #expect(await installer.status(.herdrPlugin) == .installed)
        let again = try await installer.install(.herdrPlugin)
        #expect(again.changedFiles.isEmpty, "a second install rewrites nothing")
        _ = try await installer.uninstall(.herdrPlugin)
        #expect(await commands.lines.contains("herdr plugin unlink gloss >/dev/null 2>&1"))
        #expect(!FileManager.default.fileExists(atPath: installer.pluginDirectory) && !FileManager.default.fileExists(atPath: installer.hostFilePath))
        #expect(await installer.status(.herdrPlugin) == .notInstalled)
    }

    /// Links the real bundle into the running Herdr from a temporary HOME, checks the action is listed, unlinks it,
    /// and removes the state and config directories Herdr created for the plugin id.
    @Test(.enabled(if: TestGates.herdr))
    func linksIntoTheLiveHerdrAndUnlinks() async throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-plugin-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let installer = HookInstaller(fileSystem: LocalFileSystem(deleteBehavior: .permanent), home: home, port: 47831) { try await LocalShell.run($0) }
        let before = try await LocalShell.run("herdr plugin list --json").stdoutText
        if before.contains("\"plugin_id\":\"gloss\"") { return }   // the user's real install; leave it alone
        func removeHerdrDirectories() {
            for leftover in [".local/state/herdr/plugins/gloss", ".config/herdr/plugins/config/gloss"] {
                try? FileManager.default.removeItem(atPath: (NSHomeDirectory() as NSString).appendingPathComponent(leftover))
            }
        }
        do {
            let report = try await installer.install(.herdrPlugin)
            #expect(report.changedFiles.contains { $0.hasSuffix("herdr-plugin.toml") })
            let actions = try await LocalShell.run("herdr plugin action list").stdoutText
            #expect(actions.contains("note-from-selection") && actions.contains("open-link"))
            #expect(await installer.status(.herdrPlugin) == .installed)
        } catch {
            _ = try? await installer.uninstall(.herdrPlugin)
            removeHerdrDirectories()
            throw error
        }
        _ = try await installer.uninstall(.herdrPlugin)
        let after = try await LocalShell.run("herdr plugin list --json").stdoutText
        #expect(!after.contains("\"plugin_id\":\"gloss\""))
        removeHerdrDirectories()
    }
}
