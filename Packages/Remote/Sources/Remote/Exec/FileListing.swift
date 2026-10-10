import Core
import Foundation

/// Every file under a root, for Open Quickly: `rg --files` when available (it honours .gitignore); else, in a git
/// work tree, `git ls-files` (tracked and untracked, ignored left out, as rg lists them); else `find`. `.git` and
/// `node_modules` are skipped and the list stops at `limit` paths. Without rg, `find` listed every build product
/// (`.build`, `dist`, `DerivedData`), which could fill the list before the sources.
public enum FileListing {
    public static let limit = 50_000

    /// The shell command for a host.
    public static func script(root: String, tools: RemoteTools) -> String {
        let quoted = ShellQuote.single(root)
        if tools.rg {
            return "rg --files --hidden --no-messages --glob '!.git' --glob '!node_modules' -- \(quoted) | head -n \(limit)"
        }
        let find = "find \(quoted) \\( -name .git -o -name node_modules \\) -prune -o -type f -print 2>/dev/null"
        guard tools.git else { return find + " | head -n \(limit)" }
        // A folder its repository ignores lists nothing in git: then find. Paths git still tracks but that are gone
        // from disk are left out.
        let git = "git -C \(quoted) -c core.quotePath=false ls-files -co --exclude-standard -- . \(ShellQuote.single(gitExclusion)) 2>/dev/null"
        return "r=\(quoted); if [ -n \"$(\(git) | head -n 1)\" ]; then \(git) | while IFS= read -r f; do [ -e \"$r/$f\" ] && printf '%s/%s\\n' \"$r\" \"$f\"; done; else \(find); fi | head -n \(limit)"
    }

    /// The pathspec that keeps `node_modules` out of a git listing, as the other tools' globs do.
    static let gitExclusion = ":(exclude,glob)**/node_modules/**"

    /// git on this Mac, where the explorer finds it for .gitignore.
    public static let localGit: String? = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }

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
    public static func listLocally(root: String, ripgrep: String?, git: String? = localGit) async -> [String] {
        if ripgrep == nil, let git, let listed = await gitListing(root: root, git: git) { return listed }
        let command = localCommand(root: root, ripgrep: ripgrep)
        guard let process = try? ChildProcess.launch(ChildProcessSpec(executable: command.executable, arguments: command.arguments)) else { return [] }
        return await collect(process)
    }

    /// `git ls-files` under `root` as absolute paths, without tracked files deleted from disk; nil outside a work
    /// tree, or when git lists nothing there (a folder its repository ignores), so `find` lists it instead.
    static func gitListing(root: String, git: String) async -> [String]? {
        let base = ["-C", root, "ls-files", "-z", "--exclude-standard"]
        guard let process = try? ChildProcess.launch(ChildProcessSpec(executable: git, arguments: base + ["-co", "--", ".", gitExclusion])) else { return nil }
        let relative = await collect(process, separator: 0)
        guard (try? await process.exitCode) == 0, !relative.isEmpty, !Task.isCancelled else { return nil }
        var deleted: Set<String> = []
        if let gone = try? ChildProcess.launch(ChildProcessSpec(executable: git, arguments: base + ["-d", "--", "."])) {
            deleted = Set(await collect(gone, separator: 0))
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return relative.filter { !deleted.contains($0) }.map { prefix + $0 }
    }

    /// Reads paths line by line (or NUL by NUL) and terminates the tool once `limit` have arrived (a root such as
    /// `~` would otherwise be walked in full and held in memory) or when the task is cancelled.
    private static func collect(_ process: ChildProcess, separator: UInt8 = 0x0A) async -> [String] {
        await withTaskCancellationHandler {
            var paths: [String] = []
            var pending = Data()
            for await chunk in process.stdout {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: separator) {
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
