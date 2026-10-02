import Core
import Foundation
import Observation
import OSLog
import Remote

struct SearchHit: Identifiable, Hashable, Sendable {
    var path: String
    var line: Int
    var text: String
    var id: String { "\(path):\(line)" }
}

/// Content search over the selected root with ripgrep (grep as a fallback), streaming results.
@MainActor
@Observable
final class ContentSearchModel {
    var query = ""
    private(set) var hits: [SearchHit] = []
    private(set) var isSearching = false
    private(set) var truncated = false
    var isVisible = false
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated static let ripgrepPath: String? = {
        ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
    }

    func search(in root: String, connection: SSHConnection? = nil) {
        cancel()
        let pattern = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            hits = []
            return
        }
        isSearching = true
        truncated = false
        task = Task { [weak self] in
            var results: [SearchHit] = []
            if let connection {
                do {
                    for try await hit in RemoteSearch.run(pattern: pattern, root: root, over: connection) {
                        results.append(SearchHit(path: hit.path, line: hit.line, text: hit.text))
                        if results.count > 500 { break }
                    }
                } catch {
                    Log.explorer.error("remote search failed: \(error, privacy: .public)")
                }
            } else {
                results = await Self.run(pattern: pattern, root: root)
            }
            guard !Task.isCancelled, let self else { return }
            self.hits = Array(results.prefix(500))
            self.truncated = results.count > 500
            self.isSearching = false
        }
    }

    var groupedHits: [(path: String, hits: [SearchHit])] {
        var order: [String] = []
        var groups: [String: [SearchHit]] = [:]
        for hit in hits {
            if groups[hit.path] == nil { order.append(hit.path) }
            groups[hit.path, default: []].append(hit)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// Runs the search tool off the main actor and parses its output; cancelling the task terminates the child.
    @concurrent nonisolated private static func run(pattern: String, root: String) async -> [SearchHit] {
        if let rg = ripgrepPath {
            return await runRipgrep(rg, pattern: pattern, root: root)
        }
        return await runGrep(pattern: pattern, root: root)
    }

    nonisolated private static func runRipgrep(_ rg: String, pattern: String, root: String) async -> [SearchHit] {
        let arguments = ["--json", "-n", "--no-messages", "--max-count", "200", "--max-filesize", "2M", "-e", pattern, "--", root]
        guard let data = await output(of: rg, arguments: arguments) else { return [] }
        var hits: [SearchHit] = []
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "match",
                  let payload = object["data"] as? [String: Any],
                  let path = (payload["path"] as? [String: Any])?["text"] as? String,
                  let lineNumber = payload["line_number"] as? Int,
                  let text = (payload["lines"] as? [String: Any])?["text"] as? String else { continue }
            hits.append(SearchHit(path: path, line: lineNumber, text: text.trimmingCharacters(in: .newlines)))
        }
        return hits
    }

    nonisolated private static func runGrep(pattern: String, root: String) async -> [SearchHit] {
        guard let data = await output(of: "/usr/bin/grep", arguments: ["-rnI", "--exclude-dir=.git", "-e", pattern, "--", root]) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]) else { return nil }
            return SearchHit(path: String(parts[0]), line: number, text: String(parts[2]))
        }
    }

    /// Everything the tool wrote to stdout by the time it exited, or nil when it could not start or the search was
    /// cancelled. rg and grep exit 1 when nothing matched, so the exit status is not an error here; stderr is dropped.
    nonisolated private static func output(of executable: String, arguments: [String]) async -> Data? {
        guard let process = try? ChildProcess.launch(ChildProcessSpec(executable: executable, arguments: arguments)) else { return nil }
        let data = await withTaskCancellationHandler {
            await process.collectStdout()
        } onCancel: {
            process.terminate()
        }
        _ = try? await process.exitCode
        return Task.isCancelled ? nil : data
    }
}
