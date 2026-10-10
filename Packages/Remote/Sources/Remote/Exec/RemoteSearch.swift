import Core
import Foundation
import Synchronization

public struct RemoteSearchHit: Sendable, Hashable {
    public var path: String
    public var line: Int
    public var text: String
}

/// Content search over the exec channel: `rg --json` when the host has it, `grep -rn` otherwise.
public enum RemoteSearch {
    public static let maxMatchesPerFile = 200

    /// The pattern is literal text unless `regex` is set (typing `foo(` or `[String]` used to be a regex error
    /// that showed as no matches). Case is ignored unless the pattern has a capital letter (smart case).
    public static func script(pattern: String, root: String, tools: RemoteTools, regex: Bool = false, hidden: Bool = false) -> String {
        if tools.rg {
            // Constant flags as they are; the glob is quoted, as the shell would read `!` and `*` in it.
            let flags = (ripgrepFlags(regex: regex) + ripgrepHiddenFlags(hidden).map { $0.hasPrefix("-") ? $0 : ShellQuote.single($0) }).joined(separator: " ")
            return "rg --json -n --no-messages --max-count \(maxMatchesPerFile) --max-filesize 2M \(flags) -e \(ShellQuote.single(pattern)) -- \(ShellQuote.single(root))"
        }
        let excludes = (["--exclude-dir=.git"] + grepHiddenFlags(hidden, root: root).map(ShellQuote.single)).joined(separator: " ")
        return "grep -rnI \(grepOutputFlags.joined(separator: " ")) \(excludes) \(grepFlags(pattern: pattern, regex: regex).joined(separator: " ")) -e \(ShellQuote.single(pattern)) -- \(ShellQuote.single(root))"
    }

    /// Hidden files and folders (dotfiles: `.github/`, `.env.example`) are searched when the explorer shows them,
    /// and left out when it hides them, by either tool; `.git` never is. rg skips them unless told; grep searches
    /// them unless told.
    public static func ripgrepHiddenFlags(_ hidden: Bool) -> [String] {
        hidden ? ["--hidden", "--glob", "!.git"] : []
    }

    /// A root that is itself a dot-folder (`~/.config`) is still searched: only what is inside it is left out.
    public static func grepHiddenFlags(_ hidden: Bool, root: String) -> [String] {
        guard !hidden else { return [] }
        return PathUtilities.name(of: root).hasPrefix(".") ? ["--exclude=.*"] : ["--exclude=.*", "--exclude-dir=.*"]
    }

    /// How grep reports hits, here and on this Mac: the path ends with a NUL (a colon may be part of a file name,
    /// `notes 10:30.md`), and a file stops at as many matches as rg's `--max-count`. BSD and GNU grep both take these.
    public static let grepOutputFlags = ["--null", "-m", "\(maxMatchesPerFile)"]

    /// rg and grep exit 2 both for a bad pattern and when any file under the root is unreadable, so a search that
    /// found nothing with status 2 is checked again against `/dev/null`: only a 2 from that means the pattern
    /// itself is invalid.
    public static func patternCheckScript(pattern: String, tools: RemoteTools, regex: Bool) -> String {
        if tools.rg {
            return "rg --no-messages \(ripgrepFlags(regex: regex).joined(separator: " ")) -e \(ShellQuote.single(pattern)) -- /dev/null"
        }
        return "grep -s \(grepFlags(pattern: pattern, regex: regex).joined(separator: " ")) -e \(ShellQuote.single(pattern)) /dev/null"
    }

    /// Whether the host's tool accepts the pattern.
    public static func patternIsValid(_ pattern: String, regex: Bool, over connection: SSHConnection) async -> Bool {
        guard regex, let tools = try? await connection.tools(),
              let result = try? await connection.exec(patternCheckScript(pattern: pattern, tools: tools, regex: regex), timeout: .seconds(10)) else { return true }
        return result.exitStatus != 2
    }

    /// Search flags shared by the local and remote searches.
    public static func ripgrepFlags(regex: Bool) -> [String] {
        (regex ? [] : ["--fixed-strings"]) + ["--smart-case"]
    }

    public static func grepFlags(pattern: String, regex: Bool) -> [String] {
        [regex ? "-E" : "-F"] + (pattern.contains(where: \.isUppercase) ? [] : ["-i"])
    }

    /// Streams hits as they arrive; cancelling the consumer terminates the remote command.
    public static func run(pattern: String, root: String, regex: Bool = false, hidden: Bool = false, over connection: SSHConnection) -> AsyncThrowingStream<RemoteSearchHit, any Error> {
        AsyncThrowingStream { continuation in
            let running = Mutex<ChildProcess?>(nil)
            let task = Task {
                do {
                    let tools = try await connection.tools()
                    let process = try await connection.execStreaming(script(pattern: pattern, root: root, tools: tools, regex: regex, hidden: hidden))
                    running.withLock { $0 = process }
                    if Task.isCancelled { process.terminate() }
                    var pending = Data()
                    for await chunk in process.stdout {
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: 0x0A) {
                            let line = pending.subdata(in: pending.startIndex..<newline)
                            pending.removeSubrange(pending.startIndex...newline)
                            if let hit = parse(line: line, ripgrep: tools.rg) { continuation.yield(hit) }
                        }
                    }
                    if !pending.isEmpty, let hit = parse(line: pending, ripgrep: tools.rg) { continuation.yield(hit) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // One handler for both phases: before the process exists it cancels the task, afterwards it also kills ssh.
            continuation.onTermination = { _ in
                task.cancel()
                running.withLock { $0 }?.terminate()
            }
        }
    }

    public static func parse(line: Data, ripgrep: Bool) -> RemoteSearchHit? {
        if ripgrep {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "match",
                  let payload = object["data"] as? [String: Any],
                  let path = (payload["path"] as? [String: Any])?["text"] as? String,
                  let number = payload["line_number"] as? Int,
                  let text = (payload["lines"] as? [String: Any])?["text"] as? String else { return nil }
            return RemoteSearchHit(path: path, line: number, text: text.trimmingCharacters(in: .newlines))
        }
        // `path NUL line:text` (`grepOutputFlags`).
        guard let nul = line.firstIndex(of: 0) else { return nil }
        let rest = String(decoding: line[line.index(after: nul)...], as: UTF8.self)
        let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let number = Int(parts[0]) else { return nil }
        return RemoteSearchHit(path: String(decoding: line[..<nul], as: UTF8.self), line: number, text: String(parts[1]))
    }
}
