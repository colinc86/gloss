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
    /// Off: the query is literal text. On: a regular expression.
    var isRegex = false
    /// Shown instead of "No matches" when the tool rejected the pattern (an invalid regular expression).
    private(set) var errorMessage: String?
    private(set) var hits: [SearchHit] = []
    private(set) var isSearching = false
    private(set) var truncated = false
    /// The pattern the shown results are for (the field may have been edited since), and whether it was a regex;
    /// the results view highlights matches with it.
    private(set) var searchedPattern: (text: String, regex: Bool)?
    var isVisible = false
    /// Bumped by Find in Files so the field takes the caret even when the search is already showing.
    var focusRequest = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated static let ripgrepPath: String? = {
        ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Shows an error instead of results (the root's host is not connected).
    func fail(_ message: String) {
        cancel()
        hits = []
        errorMessage = message
    }

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
        errorMessage = nil
        let regex = isRegex
        searchedPattern = (pattern, regex)
        task = Task { [weak self] in
            var results: [SearchHit] = []
            var failed = false
            if let connection {
                do {
                    for try await hit in RemoteSearch.run(pattern: pattern, root: root, regex: regex, over: connection) {
                        results.append(SearchHit(path: hit.path, line: hit.line, text: hit.text))
                        if results.count > 500 { break }
                    }
                } catch {
                    Log.explorer.error("remote search failed: \(error, privacy: .public)")
                    failed = true
                }
                if results.isEmpty, regex, await !RemoteSearch.patternIsValid(pattern, regex: true, over: connection) {
                    failed = true
                }
            } else {
                (results, failed) = await Self.run(pattern: pattern, root: root, regex: regex)
            }
            guard !Task.isCancelled, let self else { return }
            if failed, results.isEmpty { self.errorMessage = regex ? "Not a valid regular expression" : "Search failed" }
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
    /// The hits, and whether the tool reported an error (exit status 2: a bad pattern, an unreadable root).
    @concurrent nonisolated private static func run(pattern: String, root: String, regex: Bool) async -> ([SearchHit], Bool) {
        if let rg = ripgrepPath {
            return await runRipgrep(rg, pattern: pattern, root: root, regex: regex)
        }
        return await runGrep(pattern: pattern, root: root, regex: regex)
    }

    nonisolated private static func runRipgrep(_ rg: String, pattern: String, root: String, regex: Bool) async -> ([SearchHit], Bool) {
        let arguments = ["--json", "-n", "--no-messages", "--max-count", "200", "--max-filesize", "2M"] + RemoteSearch.ripgrepFlags(regex: regex) + ["-e", pattern, "--", root]
        guard let (data, status) = await output(of: rg, arguments: arguments) else { return ([], false) }
        // Status 2 also means "some file was unreadable"; only a pattern the tool rejects on its own is an error.
        let rejected = status == 2 ? await output(of: rg, arguments: ["--no-messages"] + RemoteSearch.ripgrepFlags(regex: regex) + ["-e", pattern, "--", "/dev/null"])?.1 == 2 : false
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
        return (hits, rejected)
    }

    nonisolated private static func runGrep(pattern: String, root: String, regex: Bool) async -> ([SearchHit], Bool) {
        let arguments = ["-rnIs"] + RemoteSearch.grepOutputFlags + ["--exclude-dir=.git"] + RemoteSearch.grepFlags(pattern: pattern, regex: regex) + ["-e", pattern, "--", root]
        guard let (data, status) = await output(of: "/usr/bin/grep", arguments: arguments) else { return ([], false) }
        let rejected = status == 2 ? await output(of: "/usr/bin/grep", arguments: ["-s"] + RemoteSearch.grepFlags(pattern: pattern, regex: regex) + ["-e", pattern, "/dev/null"])?.1 == 2 : false
        let hits: [SearchHit] = data.split(separator: 0x0A).compactMap { line in
            RemoteSearch.parse(line: Data(line), ripgrep: false).map { SearchHit(path: $0.path, line: $0.line, text: $0.text) }
        }
        return (hits, rejected)
    }

    /// Everything the tool wrote to stdout by the time it exited, or nil when it could not start or the search was
    /// cancelled. rg and grep exit 1 when nothing matched, so the exit status is not an error here; stderr is dropped.
    nonisolated private static func output(of executable: String, arguments: [String]) async -> (Data, Int32)? {
        guard let process = try? ChildProcess.launch(ChildProcessSpec(executable: executable, arguments: arguments)) else { return nil }
        let data = await withTaskCancellationHandler {
            await process.collectStdout()
        } onCancel: {
            process.terminate()
        }
        let status = (try? await process.exitCode) ?? 0
        return Task.isCancelled ? nil : (data, status)
    }
}
