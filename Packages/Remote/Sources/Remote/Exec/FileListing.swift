import Core
import Foundation

/// Every file under a root, for Open Quickly: `rg --files` when available (it honours .gitignore), else `find`.
/// `.git` and `node_modules` are skipped and the list stops at `limit` paths.
public enum FileListing {
    public static let limit = 50_000

    /// The shell command for a host.
    public static func script(root: String, tools: RemoteTools) -> String {
        let quoted = ShellQuote.single(root)
        if tools.rg {
            return "rg --files --hidden --no-messages --glob '!.git' --glob '!node_modules' -- \(quoted) | head -n \(limit)"
        }
        return "find \(quoted) \\( -name .git -o -name node_modules \\) -prune -o -type f -print 2>/dev/null | head -n \(limit)"
    }

    /// The executable and arguments for this Mac.
    public static func localCommand(root: String, ripgrep: String?) -> (executable: String, arguments: [String]) {
        if let ripgrep {
            return (ripgrep, ["--files", "--hidden", "--no-messages", "--glob", "!.git", "--glob", "!node_modules", "--", root])
        }
        return ("/usr/bin/find", [root, "(", "-name", ".git", "-o", "-name", "node_modules", ")", "-prune", "-o", "-type", "f", "-print"])
    }

    /// Absolute paths from the tool's output, at most `limit`.
    public static func parse(_ output: Data) -> [String] {
        String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).prefix(limit).map(String.init)
    }

    /// Lists a remote root over the exec channel, streamed (no timeout: a slow host still yields its list);
    /// cancelling the task stops the remote command.
    public static func list(root: String, over connection: SSHConnection) async throws -> [String] {
        let tools = try await connection.tools()
        let process = try await connection.execStreaming(script(root: root, tools: tools))
        return await collect(process)
    }

    /// Lists a local root; stops the tool at `limit` paths, and when the task is cancelled.
    public static func listLocally(root: String, ripgrep: String?) async -> [String] {
        let command = localCommand(root: root, ripgrep: ripgrep)
        guard let process = try? ChildProcess.launch(ChildProcessSpec(executable: command.executable, arguments: command.arguments)) else { return [] }
        return await collect(process)
    }

    /// Reads paths line by line and terminates the tool once `limit` have arrived (a root such as `~` would
    /// otherwise be walked in full and held in memory) or when the task is cancelled.
    private static func collect(_ process: ChildProcess) async -> [String] {
        await withTaskCancellationHandler {
            var paths: [String] = []
            var pending = Data()
            for await chunk in process.stdout {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending.subdata(in: pending.startIndex..<newline)
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty { paths.append(String(decoding: line, as: UTF8.self)) }
                }
                if paths.count >= limit || Task.isCancelled {
                    process.terminate()
                    break
                }
            }
            if paths.count < limit, !pending.isEmpty { paths.append(String(decoding: pending, as: UTF8.self)) }
            _ = try? await process.exitCode
            return Array(paths.prefix(limit))
        } onCancel: {
            process.terminate()
        }
    }
}
