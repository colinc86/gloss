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
    public static func script(pattern: String, root: String, tools: RemoteTools, regex: Bool = false) -> String {
        if tools.rg {
            return "rg --json -n --no-messages --max-count \(maxMatchesPerFile) --max-filesize 2M \(ripgrepFlags(regex: regex).joined(separator: " ")) -e \(ShellQuote.single(pattern)) -- \(ShellQuote.single(root))"
        }
        return "grep -rnI --exclude-dir=.git \(grepFlags(pattern: pattern, regex: regex).joined(separator: " ")) -e \(ShellQuote.single(pattern)) -- \(ShellQuote.single(root))"
    }

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
    public static func run(pattern: String, root: String, regex: Bool = false, over connection: SSHConnection) -> AsyncThrowingStream<RemoteSearchHit, any Error> {
        AsyncThrowingStream { continuation in
            let running = Mutex<ChildProcess?>(nil)
            let task = Task {
                do {
                    let tools = try await connection.tools()
                    let process = try await connection.execStreaming(script(pattern: pattern, root: root, tools: tools, regex: regex))
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

    static func parse(line: Data, ripgrep: Bool) -> RemoteSearchHit? {
        if ripgrep {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "match",
                  let payload = object["data"] as? [String: Any],
                  let path = (payload["path"] as? [String: Any])?["text"] as? String,
                  let number = payload["line_number"] as? Int,
                  let text = (payload["lines"] as? [String: Any])?["text"] as? String else { return nil }
            return RemoteSearchHit(path: path, line: number, text: text.trimmingCharacters(in: .newlines))
        }
        let text = String(decoding: line, as: UTF8.self)
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let number = Int(parts[1]) else { return nil }
        return RemoteSearchHit(path: String(parts[0]), line: number, text: String(parts[2]))
    }
}
