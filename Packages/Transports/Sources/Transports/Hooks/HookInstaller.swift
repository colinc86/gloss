import Core
import CryptoKit
import Foundation
import Remote

/// Which agent's configuration an install touches.
public enum HookAgent: String, Sendable, CaseIterable, Identifiable {
    case claude
    case codex
    case opencode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }
}

public enum HookStatus: Sendable, Equatable {
    case notInstalled
    case installed
    /// Installed, but the script or the config entry differs from what this build would write.
    case outdated(String)
}

public struct HookInstallReport: Sendable, Equatable {
    public var changedFiles: [String] = []
    public var backups: [String] = []
    /// Things the user has to do by hand, e.g. trust the hook inside Codex, or register MCP when the CLI is missing.
    public var notices: [String] = []
}

public enum HookInstallerError: Error, Sendable, Equatable {
    case unparsable(path: String, reason: String)
    case bundledScriptMissing
}

/// Installs the hook script and the per-agent configuration on a file system (this Mac or a host over SFTP), merging
/// into existing files: every entry that is not ours is preserved byte for byte at the value level.
public struct HookInstaller: Sendable {
    public static let scriptName = "gloss-notes.sh"
    public static let mcpServerName = MCPServer.serverName
    /// Keep this many backups per file.
    public static let backupsToKeep = 3

    public var fileSystem: any FileSystemProvider
    public var home: String
    /// Set on remote hosts: the hook command exports `GLOSS_HOST=<alias>` so the server attributes the notes correctly.
    public var hostAlias: String?
    /// Runs one shell line (`sh -c`) where the files live, for the agents' own `mcp add` commands.
    public var run: @Sendable (String) async throws -> ExecResult
    public var port: Int
    public var now: @Sendable () -> Date = { Date() }

    public init(fileSystem: any FileSystemProvider, home: String, hostAlias: String? = nil, port: Int, run: @escaping @Sendable (String) async throws -> ExecResult) {
        self.fileSystem = fileSystem
        self.home = home
        self.hostAlias = hostAlias
        self.port = port
        self.run = run
    }

    // MARK: Paths and commands

    public var scriptPath: String { PathUtilities.join(home, ".claude/hooks/\(Self.scriptName)") }
    public var claudeSettingsPath: String { PathUtilities.join(home, ".claude/settings.json") }
    public var codexHooksPath: String { PathUtilities.join(home, ".codex/hooks.json") }
    public var codexConfigPath: String { PathUtilities.join(home, ".codex/config.toml") }
    public var opencodeConfigPath: String { PathUtilities.join(home, ".config/opencode/opencode.json") }
    /// Remote hosts have no Application Support; the script reads the port from here.
    public var remotePortFilePath: String { PathUtilities.join(home, ".config/gloss/mcp-port") }
    public var mcpURL: String { "http://127.0.0.1:\(port)/mcp" }

    public func hookCommand(for agent: HookAgent) -> String {
        let prefix = hostAlias.map { "GLOSS_HOST=\(ShellQuote.single($0)) " } ?? ""
        return "\(prefix)\"$HOME/.claude/hooks/\(Self.scriptName)\" \(agent.rawValue)"
    }

    public static func bundledScript() throws -> Data {
        guard let url = Bundle.module.url(forResource: "gloss-notes", withExtension: "sh", subdirectory: "HookScripts"),
              let data = FileManager.default.contents(atPath: url.path) else { throw HookInstallerError.bundledScriptMissing }
        return data
    }

    // MARK: Install

    public func install(_ agent: HookAgent) async throws -> HookInstallReport {
        var report = HookInstallReport()
        switch agent {
        case .claude:
            try await installScript(into: &report)
            try await mergeHookFile(at: claudeSettingsPath, command: hookCommand(for: .claude), report: &report)
            await registerMCP(remove: "claude mcp remove -s user \(Self.mcpServerName) >/dev/null 2>&1", add: "claude mcp add -s user --transport http \(Self.mcpServerName) \(mcpURL)", fallback: "Register the MCP server by hand: \(MCPServer.snippets(port: port).claudeCommand)", report: &report)
        case .codex:
            try await installScript(into: &report)
            try await mergeHookFile(at: codexHooksPath, command: hookCommand(for: .codex), report: &report)
            try await enableCodexHooks(report: &report)
            await registerMCP(remove: "codex mcp remove \(Self.mcpServerName) >/dev/null 2>&1", add: "codex mcp add \(Self.mcpServerName) --url \(mcpURL)", fallback: "Register the MCP server by hand: \(MCPServer.snippets(port: port).codexCommand)", report: &report)
            report.notices.append("Codex skips new hooks until you trust them: run /hooks inside Codex and trust the Gloss entry.")
        case .opencode:
            try await mergeOpenCodeConfig(report: &report)
        }
        return report
    }

    public func uninstall(_ agent: HookAgent) async throws -> HookInstallReport {
        var report = HookInstallReport()
        switch agent {
        case .claude:
            try await mergeHookFile(at: claudeSettingsPath, command: nil, report: &report)
            _ = try? await run("claude mcp remove -s user \(Self.mcpServerName) >/dev/null 2>&1")
        case .codex:
            try await mergeHookFile(at: codexHooksPath, command: nil, report: &report)
            _ = try? await run("codex mcp remove \(Self.mcpServerName) >/dev/null 2>&1")
        case .opencode:
            try await mergeOpenCodeConfig(remove: true, report: &report)
        }
        if agent != .opencode, !(try await hookFileMentionsScript(claudeSettingsPath)), !(try await hookFileMentionsScript(codexHooksPath)) {
            for path in [scriptPath] + (hostAlias != nil ? [remotePortFilePath] : []) where (try? await fileSystem.delete(path)) != nil {
                report.changedFiles.append(path)
            }
        }
        return report
    }

    public func status(_ agent: HookAgent) async -> HookStatus {
        switch agent {
        case .claude, .codex:
            let path = agent == .claude ? claudeSettingsPath : codexHooksPath
            guard let data = try? await fileSystem.read(path), Self.hasOurEntry(in: data) else { return .notInstalled }
            guard let installed = try? await fileSystem.read(scriptPath) else { return .outdated("hook script is missing") }
            if let bundled = try? Self.bundledScript(), Self.sha256(installed) != Self.sha256(bundled) { return .outdated("hook script differs from this build") }
            if !Self.hasEntry(in: data, command: hookCommand(for: agent)) { return .outdated("hook command differs") }
            if agent == .codex, let toml = try? await fileSystem.read(codexConfigPath), !Self.codexHooksEnabled(String(decoding: toml, as: UTF8.self)) {
                return .outdated("[features] hooks is not enabled")
            }
            if hostAlias != nil, (try? await fileSystem.read(remotePortFilePath)) != Data("\(port)\n".utf8) {
                return .outdated("port file does not match port \(port)")
            }
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

    private func installScript(into report: inout HookInstallReport) async throws {
        let bundled = try Self.bundledScript()
        try await fileSystem.makeDirectory(PathUtilities.parent(of: scriptPath))
        if hostAlias != nil {
            // The port can change between installs while the script and the hook entry stay the same.
            let portLine = Data("\(port)\n".utf8)
            if try await readIfPresent(remotePortFilePath) != portLine {
                try await fileSystem.makeDirectory(PathUtilities.parent(of: remotePortFilePath))
                _ = try await fileSystem.writeAtomically(portLine, to: remotePortFilePath, preservingModeFrom: nil)
                report.changedFiles.append(remotePortFilePath)
            }
        }
        if try await readIfPresent(scriptPath) == bundled { return }
        let executable = FileAttributes(kind: .file, size: Int64(bundled.count), mtime: now(), mode: 0o755)
        _ = try await fileSystem.writeAtomically(bundled, to: scriptPath, preservingModeFrom: executable)
        report.changedFiles.append(scriptPath)
    }

    /// Rewrites `hooks.UserPromptSubmit` so exactly one entry is ours (`command` nil removes it).
    private func mergeHookFile(at path: String, command: String?, report: inout HookInstallReport) async throws {
        let original = try await readIfPresent(path)
        let merged = try Self.mergeHookEntry(into: original ?? Data("{}".utf8), command: command, path: path)
        if original == merged { return }
        try await writeWithBackup(merged, to: path, original: original, report: &report)
    }

    private func enableCodexHooks(report: inout HookInstallReport) async throws {
        let original = (try await readIfPresent(codexConfigPath)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let updated = Self.enableCodexHooks(in: original)
        if updated == original { return }
        try await writeWithBackup(Data(updated.utf8), to: codexConfigPath, original: Data(original.utf8), report: &report)
    }

    private func mergeOpenCodeConfig(remove: Bool = false, report: inout HookInstallReport) async throws {
        let original = try await readIfPresent(opencodeConfigPath)
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
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
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
        let backups = entries.filter { $0.name.hasPrefix(name) }.map(\.name).sorted()
        for old in backups.dropLast(Self.backupsToKeep) {
            try? await fileSystem.delete(PathUtilities.join(PathUtilities.parent(of: path), old))
        }
    }

    private func hookFileMentionsScript(_ path: String) async throws -> Bool {
        guard let data = try? await fileSystem.read(path) else { return false }
        return Self.hasOurEntry(in: data)
    }

    // MARK: Pure merge logic

    static let jsonOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    nonisolated static func isOurs(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any], let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(scriptName) == true }
    }

    /// Strips our handler from a group; nil when nothing else is left in it.
    nonisolated static func withoutOurHandler(_ entry: Any) -> Any? {
        guard var group = entry as? [String: Any], let hooks = group["hooks"] as? [[String: Any]] else { return entry }
        let others = hooks.filter { ($0["command"] as? String)?.contains(scriptName) != true }
        if others.count == hooks.count { return entry }
        guard !others.isEmpty else { return nil }
        group["hooks"] = others
        return group
    }

    public nonisolated static func hasOurEntry(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let submit = (object["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [Any] else { return false }
        return submit.contains(where: isOurs)
    }

    nonisolated static func hasEntry(in data: Data, command: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let submit = (object["hooks"] as? [String: Any])?["UserPromptSubmit"] as? [[String: Any]] else { return false }
        return submit.contains { entry in (entry["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == command } == true }
    }

    /// Removes every previous Gloss entry from `hooks.UserPromptSubmit` and appends one for `command`.
    public nonisolated static func mergeHookEntry(into data: Data, command: String?, path: String = "settings.json") throws -> Data {
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
        var submit = (hooks["UserPromptSubmit"] as? [Any] ?? []).compactMap(withoutOurHandler)
        if let command {
            submit.append(["hooks": [["type": "command", "command": command, "timeout": 10]]])
        }
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

    /// Ensures `[features]\nhooks = true` without rewriting any other line.
    public nonisolated static func enableCodexHooks(in toml: String) -> String {
        let newline = toml.contains("\r\n") ? "\r\n" : "\n"
        var lines = toml.components(separatedBy: newline)
        func stripped(_ line: String) -> String {
            // The value without a trailing comment or line ending.
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
            return code.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let header = lines.firstIndex(where: { stripped($0) == "[features]" }) else {
            var out = toml
            if !out.isEmpty, !out.hasSuffix(newline) { out += newline }
            if !out.isEmpty { out += newline }
            return out + "[features]\(newline)hooks = true\(newline)"
        }
        var index = header + 1
        while index < lines.count {
            let code = stripped(lines[index])
            if code.hasPrefix("[") { break }
            if code.hasPrefix("hooks"), code.dropFirst(5).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                let value = code.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if value == "true" { return toml }
                lines[index] = "hooks = true"
                return lines.joined(separator: newline)
            }
            index += 1
        }
        lines.insert("hooks = true", at: header + 1)
        return lines.joined(separator: newline)
    }

    public nonisolated static func codexHooksEnabled(_ toml: String) -> Bool {
        enableCodexHooks(in: toml) == toml
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
