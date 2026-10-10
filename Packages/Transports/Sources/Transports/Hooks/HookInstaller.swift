import Core
import Foundation
import Remote

/// Which agent's configuration an install touches.
public enum HookAgent: String, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case opencode
    /// Herdr's plugin: a keybinding sends the selected text to the app as a note.
    case herdrPlugin = "herdr-plugin"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .herdrPlugin: "Herdr plugin"
        }
    }
}

public enum HookStatus: Sendable, Equatable {
    case notInstalled
    case installed
    /// Installed, but something differs from what this build would write (a stale MCP url, or the prompt hook that
    /// older builds installed).
    case outdated(String)
}

public struct HookInstallReport: Sendable, Equatable {
    public var changedFiles: [String] = []
    public var backups: [String] = []
    /// Things the user has to do by hand, e.g. register MCP when the agent's CLI is missing.
    public var notices: [String] = []
}

public enum HookInstallerError: Error, Sendable, Equatable {
    case unparsable(path: String, reason: String)
    case bundledPluginMissing
    case commandFailed(String)
}

/// Registers Gloss's MCP server with each agent and installs the Herdr plugin, on a file system (this Mac or a host
/// over SFTP), merging into existing files: every entry that is not ours is preserved byte for byte at the value level.
///
/// Builds before 0.2 also installed a `UserPromptSubmit` hook (`gloss-notes.sh`) that handed every draft under the
/// session's folder to the agent whenever any prompt was submitted, including the one a send itself submits, so
/// drafts left without the user pressing Send. Drafts now leave only on Send: install and uninstall both take that
/// hook out (with a backup), and status reports a machine that still has it as outdated.
public struct HookInstaller: Sendable {
    /// The old prompt hook's script, recognised only to remove it.
    public static let legacyScriptName = "gloss-notes.sh"
    public static let mcpServerName = MCPServer.serverName
    /// Keep this many backups per file.
    public static let backupsToKeep = 3

    public var fileSystem: any FileSystemProvider
    public var home: String
    /// Set on remote hosts: the registered MCP url carries `host=<alias>` so the server resolves the agent's paths there.
    public var hostAlias: String?
    /// Runs one shell line (`sh -c`) where the files live, for the agents' own `mcp add` commands.
    public var run: @Sendable (String) async throws -> ExecResult
    public var port: Int
    /// The server's token: written on the port file's second line and carried in the registered MCP URL.
    public var token: String?
    public var now: @Sendable () -> Date = { Date() }

    public init(fileSystem: any FileSystemProvider, home: String, hostAlias: String? = nil, port: Int, token: String? = nil, run: @escaping @Sendable (String) async throws -> ExecResult) {
        self.fileSystem = fileSystem
        self.home = home
        self.hostAlias = hostAlias
        self.port = port
        self.token = token
        self.run = run
    }

    /// The port file's content, and the mode it is written with (it holds the token).
    private var portFileContents: Data { MCPServer.portFileContents(port: port, token: token) }
    private var privateFile: FileAttributes { FileAttributes(kind: .file, size: 0, mtime: now(), mode: 0o600) }

    // MARK: Paths and commands

    public var legacyScriptPath: String { PathUtilities.join(home, ".claude/hooks/\(Self.legacyScriptName)") }
    public var claudeSettingsPath: String { PathUtilities.join(home, ".claude/settings.json") }
    public var codexHooksPath: String { PathUtilities.join(home, ".codex/hooks.json") }
    public var codexConfigPath: String { PathUtilities.join(home, ".codex/config.toml") }
    public var opencodeConfigPath: String { PathUtilities.join(home, ".config/opencode/opencode.json") }
    /// Remote hosts have no Application Support; the Herdr plugin reads the port from here.
    public var remotePortFilePath: String { PathUtilities.join(home, ".config/gloss/mcp-port") }
    /// Tells the plugin which host alias it runs on, so notes land on the right host.
    public var hostFilePath: String { PathUtilities.join(home, ".config/gloss/host") }
    /// Where the plugin bundle is copied; linking from the app bundle would break on every rebuild or update.
    public var pluginDirectory: String { PathUtilities.join(home, ".config/gloss/herdr-plugin") }
    public static let pluginID = "gloss"
    public static let pluginFiles = ["herdr-plugin.toml", "bin/gloss-plugin.sh"]
    /// Shown in Settings; the app never edits Herdr's config.
    public static let keybindingSnippet = """
    [[keys.command]]
    key = "prefix+n"
    type = "plugin_action"
    command = "gloss.note-from-selection"
    description = "send selection to Gloss"
    """
    /// On a host, the URL carries the alias so the app knows which machine the agent's paths are on.
    public var mcpURL: String { MCPServer.url(port: port, host: hostAlias, token: token) }
    private var shellMCPURL: String { mcpURL.contains("?") ? ShellQuote.single(mcpURL) : mcpURL }

    public static func bundledPluginFile(_ relativePath: String) throws -> Data {
        guard let root = Bundle.module.url(forResource: "HerdrPlugin", withExtension: nil),
              let data = FileManager.default.contents(atPath: root.appendingPathComponent(relativePath).path) else { throw HookInstallerError.bundledPluginMissing }
        return data
    }

    // MARK: Install

    public func install(_ agent: HookAgent) async throws -> HookInstallReport {
        var report = HookInstallReport()
        switch agent {
        case .claude:
            try await removeLegacyHook(at: claudeSettingsPath, report: &report)
            await registerMCP(remove: "claude mcp remove -s user \(Self.mcpServerName) >/dev/null 2>&1", add: "claude mcp add -s user --transport http \(Self.mcpServerName) \(shellMCPURL)", fallback: "Register the MCP server by hand: \(MCPServer.snippets(port: port, host: hostAlias, token: token).claudeCommand)", report: &report)
        case .codex:
            try await removeLegacyHook(at: codexHooksPath, report: &report)
            await registerMCP(remove: "codex mcp remove \(Self.mcpServerName) >/dev/null 2>&1", add: "codex mcp add \(Self.mcpServerName) --url \(shellMCPURL)", fallback: "Register the MCP server by hand: \(MCPServer.snippets(port: port, host: hostAlias, token: token).codexCommand)", report: &report)
        case .opencode:
            try await mergeOpenCodeConfig(report: &report)
        case .herdrPlugin:
            try await installPlugin(report: &report)
        }
        if agent == .claude || agent == .codex { await removeOrphanedFiles(report: &report) }
        return report
    }

    public func uninstall(_ agent: HookAgent) async throws -> HookInstallReport {
        var report = HookInstallReport()
        switch agent {
        case .claude:
            try await removeLegacyHook(at: claudeSettingsPath, report: &report)
            _ = try? await run("claude mcp remove -s user \(Self.mcpServerName) >/dev/null 2>&1")
        case .codex:
            try await removeLegacyHook(at: codexHooksPath, report: &report)
            _ = try? await run("codex mcp remove \(Self.mcpServerName) >/dev/null 2>&1")
        case .opencode:
            try await mergeOpenCodeConfig(remove: true, report: &report)
        case .herdrPlugin:
            _ = try? await run("herdr plugin unlink \(Self.pluginID) >/dev/null 2>&1")
            for path in Self.pluginFiles.map({ PathUtilities.join(pluginDirectory, $0) }) + [PathUtilities.join(pluginDirectory, "bin"), pluginDirectory, hostFilePath]
            where (try? await fileSystem.delete(path)) != nil {
                report.changedFiles.append(path)
            }
        }
        if agent != .opencode { await removeOrphanedFiles(report: &report) }
        return report
    }

    /// The old hook script once neither agent's settings run it, and the port file once neither an old hook nor the
    /// plugin reads it.
    private func removeOrphanedFiles(report: inout HookInstallReport) async {
        let claudeHook = await hookFileHasLegacyEntry(claudeSettingsPath)
        let codexHook = await hookFileHasLegacyEntry(codexHooksPath)
        let hooksRemain = claudeHook || codexHook
        let pluginRemains = (try? await fileSystem.stat(PathUtilities.join(pluginDirectory, "herdr-plugin.toml"))) != nil
        var orphaned: [String] = []
        if !hooksRemain { orphaned.append(legacyScriptPath) }
        if !hooksRemain, !pluginRemains { orphaned.append(remotePortFilePath) }
        for path in orphaned where (try? await fileSystem.delete(path)) != nil {
            report.changedFiles.append(path)
        }
    }

    /// The URL the agent's own config has for our MCP server, or nil when there is no entry to compare (the
    /// registration may have needed the manual fallback). Claude Code keeps user-scope servers in `~/.claude.json`,
    /// Codex in `[mcp_servers.<name>]` of `config.toml`.
    func registeredMCPURL(for agent: HookAgent) async -> String? {
        switch agent {
        case .claude:
            guard let data = try? await fileSystem.read(PathUtilities.join(home, ".claude.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = (object["mcpServers"] as? [String: Any])?[Self.mcpServerName] as? [String: Any] else { return nil }
            return entry["url"] as? String
        case .codex:
            guard let data = try? await fileSystem.read(codexConfigPath) else { return nil }
            return Self.codexMCPURL(in: String(decoding: data, as: UTF8.self))
        default:
            return nil
        }
    }

    /// `url = "…"` inside `[mcp_servers.gloss]` (quoted or bare table name).
    static func codexMCPURL(in toml: String) -> String? {
        var inSection = false
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
                let name = header.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).replacingOccurrences(of: "\"", with: "")
                inSection = name == "mcp_servers.\(mcpServerName)"
                continue
            }
            guard inSection, let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "url" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                let rest = value.dropFirst()
                return rest.firstIndex(of: quote).map { String(rest[..<$0]) }
            }
            return value.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public func status(_ agent: HookAgent) async -> HookStatus {
        switch agent {
        case .claude, .codex:
            if await hookFileHasLegacyEntry(agent == .claude ? claudeSettingsPath : codexHooksPath) {
                return .outdated(Self.legacyHookReason)
            }
            guard let registered = await registeredMCPURL(for: agent) else { return .notInstalled }
            return registered == mcpURL ? .installed : .outdated("MCP url differs")
        case .herdrPlugin:
            for file in Self.pluginFiles {
                guard let installed = try? await fileSystem.read(PathUtilities.join(pluginDirectory, file)) else { return .notInstalled }
                if let bundled = try? Self.bundledPluginFile(file), installed != bundled { return .outdated("\(file) differs from this build") }
            }
            guard let listed = try? await run("herdr plugin list --json"), listed.exitStatus == 0 else { return .outdated("herdr is not reachable") }
            guard listed.stdoutText.contains("\"plugin_id\":\"\(Self.pluginID)\"") else { return .outdated("not linked in Herdr") }
            if hostAlias != nil, (try? await fileSystem.read(remotePortFilePath)) != portFileContents { return .outdated("port file does not match this app (port \(port) and its token)") }
            return .installed
        case .opencode:
            guard let data = try? await fileSystem.read(opencodeConfigPath),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = (object["mcp"] as? [String: Any])?[Self.mcpServerName] as? [String: Any] else { return .notInstalled }
            return entry["url"] as? String == mcpURL ? .installed : .outdated("MCP url differs")
        }
    }

    // MARK: Steps

    /// The file's bytes, or nil only when it does not exist. Any other failure aborts the install: merging into
    /// `{}` because a read failed would replace the user's config with just our entry.
    private func readIfPresent(_ path: String) async throws -> Data? {
        do {
            return try await fileSystem.read(path)
        } catch FileSystemError.notFound {
            return nil
        }
    }

    /// Copies the plugin bundle next to the port file and links it with `herdr plugin link`.
    private func installPlugin(report: inout HookInstallReport) async throws {
        try await fileSystem.makeDirectory(PathUtilities.join(pluginDirectory, "bin"))
        for file in Self.pluginFiles {
            let bundled = try Self.bundledPluginFile(file)
            let path = PathUtilities.join(pluginDirectory, file)
            if try await readIfPresent(path) == bundled { continue }
            let mode: UInt16 = file.hasSuffix(".sh") ? 0o755 : 0o644
            _ = try await fileSystem.writeAtomically(bundled, to: path, preservingModeFrom: FileAttributes(kind: .file, size: Int64(bundled.count), mtime: now(), mode: mode))
            report.changedFiles.append(path)
        }
        let portLine = portFileContents
        if try await readIfPresent(remotePortFilePath) != portLine {
            _ = try await fileSystem.writeAtomically(portLine, to: remotePortFilePath, preservingModeFrom: privateFile)
            report.changedFiles.append(remotePortFilePath)
        }
        let hostLine = Data("\(hostAlias ?? "local")\n".utf8)
        if try await readIfPresent(hostFilePath) != hostLine {
            _ = try await fileSystem.writeAtomically(hostLine, to: hostFilePath, preservingModeFrom: nil)
            report.changedFiles.append(hostFilePath)
        }
        _ = try? await run("herdr plugin unlink \(Self.pluginID) >/dev/null 2>&1")
        let linked = try await run("herdr plugin link \(ShellQuote.single(pluginDirectory))")
        guard linked.exitStatus == 0 else {
            throw HookInstallerError.commandFailed("herdr plugin link: \(linked.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        report.notices.append("Bind a key in Herdr's config.toml:\n" + Self.keybindingSnippet)
    }

    /// Why a machine with the old prompt hook shows Update.
    public static let legacyHookReason = "An older Gloss added a prompt hook that sent drafts without Send. Update removes it."

    /// Takes the old prompt hook's entry out of `hooks.UserPromptSubmit`. A file without one (or no file at all) is
    /// not touched: no `{}` file is created, and the user's file isn't reformatted.
    private func removeLegacyHook(at path: String, report: inout HookInstallReport) async throws {
        guard let original = try await readIfPresent(path), Self.hasLegacyEntry(in: original) else { return }
        let cleaned = try Self.removingLegacyEntry(from: original, path: path)
        if original == cleaned { return }
        try await writeWithBackup(cleaned, to: path, original: original, report: &report)
    }

    private func mergeOpenCodeConfig(remove: Bool = false, report: inout HookInstallReport) async throws {
        let original = try await readIfPresent(opencodeConfigPath)
        if remove, original == nil { return }
        let merged = try Self.mergeOpenCode(into: original ?? Data("{}".utf8), url: remove ? nil : mcpURL, path: opencodeConfigPath)
        if original == merged { return }
        try await writeWithBackup(merged, to: opencodeConfigPath, original: original, report: &report)
    }

    private func registerMCP(remove: String, add: String, fallback: String, report: inout HookInstallReport) async {
        _ = try? await run(remove)
        if let result = try? await run(add), result.exitStatus == 0 { return }
        report.notices.append(fallback)
    }

    private func writeWithBackup(_ data: Data, to path: String, original: Data?, report: inout HookInstallReport) async throws {
        try await fileSystem.makeDirectory(PathUtilities.parent(of: path))
        let attributes = try? await fileSystem.stat(path)
        if let original {
            let formatter = DateFormatter()
            // UTC, so names sort in time order across a daylight-saving change and pruning keeps the newest.
            formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            var backup = "\(path).gloss-backup-\(formatter.string(from: now()))"
            // Two installs within one second must not overwrite the first backup.
            var suffix = 1
            while (try? await fileSystem.stat(backup)) != nil {
                backup = "\(path).gloss-backup-\(formatter.string(from: now()))-\(suffix)"
                suffix += 1
            }
            _ = try await fileSystem.writeAtomically(original, to: backup, preservingModeFrom: attributes)
            report.backups.append(backup)
            await pruneBackups(of: path)
        }
        _ = try await fileSystem.writeAtomically(data, to: path, preservingModeFrom: attributes)
        report.changedFiles.append(path)
    }

    private func pruneBackups(of path: String) async {
        let name = PathUtilities.name(of: path) + ".gloss-backup-"
        guard let entries = try? await fileSystem.list(PathUtilities.parent(of: path)) else { return }
        // Oldest first by modification time, then name: names from older builds used local time.
        let backups = entries.filter { $0.name.hasPrefix(name) }
            .sorted { ($0.mtime ?? .distantPast, $0.name) < ($1.mtime ?? .distantPast, $1.name) }
            .map(\.name)
        for old in backups.dropLast(Self.backupsToKeep) {
            try? await fileSystem.delete(PathUtilities.join(PathUtilities.parent(of: path), old))
        }
    }

    private func hookFileHasLegacyEntry(_ path: String) async -> Bool {
        guard let data = try? await fileSystem.read(path) else { return false }
        return Self.hasLegacyEntry(in: data)
    }

    // MARK: Pure merge logic

    static let jsonOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    nonisolated static func isOurs(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any], let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(legacyScriptName) == true }
    }

    /// Strips our handler from a group; nil when nothing else is left in it.
    nonisolated static func withoutOurHandler(_ entry: Any) -> Any? {
        guard var group = entry as? [String: Any], let hooks = group["hooks"] as? [[String: Any]] else { return entry }
        let others = hooks.filter { ($0["command"] as? String)?.contains(legacyScriptName) != true }
        if others.count == hooks.count { return entry }
        guard !others.isEmpty else { return nil }
        group["hooks"] = others
        return group
    }

    public nonisolated static func hasLegacyEntry(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let submit = (object["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [Any] else { return false }
        return submit.contains(where: isOurs)
    }

    /// The settings without any Gloss handler in `hooks.UserPromptSubmit`; empty structures it leaves are dropped.
    public nonisolated static func removingLegacyEntry(from data: Data, path: String = "settings.json") throws -> Data {
        var object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HookInstallerError.unparsable(path: path, reason: "top level is not an object") }
            object = parsed
        } catch let error as HookInstallerError {
            throw error
        } catch {
            throw HookInstallerError.unparsable(path: path, reason: "\(error)")
        }
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        let submit = (hooks["UserPromptSubmit"] as? [Any] ?? []).compactMap(withoutOurHandler)
        if submit.isEmpty { hooks["UserPromptSubmit"] = nil } else { hooks["UserPromptSubmit"] = submit }
        if hooks.isEmpty { object["hooks"] = nil } else { object["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: object, options: jsonOptions) + Data("\n".utf8)
    }

    /// `mcp.gloss = {type: remote, url, enabled: true}` in opencode.json (`url` nil removes it).
    public nonisolated static func mergeOpenCode(into data: Data, url: String?, path: String = "opencode.json") throws -> Data {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.unparsable(path: path, reason: "not a JSON object")
        }
        var object = parsed
        var mcp = object["mcp"] as? [String: Any] ?? [:]
        if let url {
            mcp[mcpServerName] = ["type": "remote", "url": url, "enabled": true]
        } else {
            mcp[mcpServerName] = nil
        }
        if mcp.isEmpty { object["mcp"] = nil } else { object["mcp"] = mcp }
        return try JSONSerialization.data(withJSONObject: object, options: jsonOptions) + Data("\n".utf8)
    }
}

/// Runs a shell line on this Mac with the agents' usual install locations on PATH.
public enum LocalShell {
    /// Shell prefix that puts the usual agent install locations (including nvm and volta) on PATH; shared with
    /// the remote exec path.
    public static let pathPrefix = "for d in \"$HOME/.local/bin\" \"$HOME/.npm-global/bin\" \"$HOME/.volta/bin\" /opt/homebrew/bin /usr/local/bin /home/linuxbrew/.linuxbrew/bin \"$HOME\"/.nvm/versions/node/*/bin; do [ -d \"$d\" ] && PATH=\"$d:$PATH\"; done; export PATH; "

    /// Runs a shell line with a deadline, so a CLI that stops for an interactive prompt cannot wedge the UI.
    public static func run(_ line: String, timeout: Duration = .seconds(60)) async throws -> ExecResult {
        let process = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sh", arguments: ["-c", pathPrefix + line], stdin: .null))
        async let out = process.collectStdout()
        async let err = process.collectStderr()
        guard let code = await withDeadline(timeout, { try? await process.exitCode }) ?? nil else {
            process.terminate()
            throw SSHError.timedOut
        }
        return ExecResult(exitStatus: code, stdout: await out, stderr: await err)
    }
}

extension HookInstallerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unparsable(let path, let reason): "\(path) couldn't be read, so it was left alone: \(reason)"
        case .bundledPluginMissing: "The Herdr plugin is missing from this copy of Gloss"
        case .commandFailed(let message): message
        }
    }
}
