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

    /// Hits shown at most.
    nonisolated static let shownLimit = 500
    /// Hits read at most before the tool is stopped. Well above `shownLimit` so the hits shown are the same each
    /// time for any search with fewer than this many, without reading all of a common word's matches in a large
    /// folder (`e` in a 3,000-file SDK was 136 MB of output, all held and parsed to show 500).
    nonisolated static let collectionLimit = 5_000

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

    /// `hidden`: search hidden files and folders too, as the explorer shows them (`.git` never).
    func search(in root: String, connection: SSHConnection? = nil, hidden: Bool = false) {
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
                    for try await hit in RemoteSearch.run(pattern: pattern, root: root, regex: regex, hidden: hidden, over: connection) {
                        results.append(SearchHit(path: hit.path, line: hit.line, text: hit.text))
                        if results.count >= Self.collectionLimit { break }
                    }
                } catch {
                    Log.explorer.error("remote search failed: \(error, privacy: .public)")
                    failed = true
                }
                if results.isEmpty, regex, await !RemoteSearch.patternIsValid(pattern, regex: true, over: connection) {
                    failed = true
                }
            } else {
                (results, failed) = await Self.run(pattern: pattern, root: root, regex: regex, hidden: hidden)
            }
            guard !Task.isCancelled, let self else { return }
            if failed, results.isEmpty { self.errorMessage = regex ? "Not a valid regular expression" : "Search failed" }
            self.hits = Array(Self.ordered(results).prefix(Self.shownLimit))
            self.truncated = results.count > Self.shownLimit
            self.isSearching = false
        }
    }

    /// Hits in the explorer's order, by path (numbers in order, as `file2` before `file10`) and then line: rg searches
    /// files in parallel and reports them as they finish, so the same search came back in a different order each time.
    nonisolated static func ordered(_ hits: [SearchHit]) -> [SearchHit] {
        hits.sorted { lhs, rhs in
            if lhs.path != rhs.path { return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending }
            return lhs.line < rhs.line
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
    @concurrent nonisolated private static func run(pattern: String, root: String, regex: Bool, hidden: Bool) async -> ([SearchHit], Bool) {
        if let rg = ripgrepPath {
            return await runRipgrep(rg, pattern: pattern, root: root, regex: regex, hidden: hidden)
        }
        return await runGrep(pattern: pattern, root: root, regex: regex, hidden: hidden)
    }

    nonisolated private static func runRipgrep(_ rg: String, pattern: String, root: String, regex: Bool, hidden: Bool) async -> ([SearchHit], Bool) {
        let arguments = ["--json", "-n", "--no-messages", "--max-count", "200", "--max-filesize", "2M"] + RemoteSearch.ripgrepFlags(regex: regex)
            + RemoteSearch.ripgrepHiddenFlags(hidden) + ["-e", pattern, "--", root]
        guard let (hits, status) = await hits(of: rg, arguments: arguments, ripgrep: true) else { return ([], false) }
        // Status 2 also means "some file was unreadable"; only a pattern the tool rejects on its own is an error.
        let rejected = status == 2 ? await self.hits(of: rg, arguments: ["--no-messages"] + RemoteSearch.ripgrepFlags(regex: regex) + ["-e", pattern, "--", "/dev/null"], ripgrep: true)?.1 == 2 : false
        return (hits, rejected)
    }

    nonisolated private static func runGrep(pattern: String, root: String, regex: Bool, hidden: Bool) async -> ([SearchHit], Bool) {
        let arguments = ["-rnIs"] + RemoteSearch.grepOutputFlags + ["--exclude-dir=.git"] + RemoteSearch.grepHiddenFlags(hidden, root: root)
            + RemoteSearch.grepFlags(pattern: pattern, regex: regex) + ["-e", pattern, "--", root]
        guard let (hits, status) = await hits(of: "/usr/bin/grep", arguments: arguments, ripgrep: false) else { return ([], false) }
        let rejected = status == 2 ? await self.hits(of: "/usr/bin/grep", arguments: ["-s"] + RemoteSearch.grepFlags(pattern: pattern, regex: regex) + ["-e", pattern, "/dev/null"], ripgrep: false)?.1 == 2 : false
        return (hits, rejected)
    }

    /// The hits the tool wrote, read line by line as it writes them (as a remote search reads them, so a line in a
    /// Latin-1 file is found here too), and its exit status; nil when it could not start or the search was cancelled.
    /// It is stopped once `collectionLimit` hits are in, and its status is then 0. rg and grep exit 1 when nothing
    /// matched, so the exit status is not an error here; stderr is dropped.
    nonisolated private static func hits(of executable: String, arguments: [String], ripgrep: Bool) async -> ([SearchHit], Int32)? {
        guard let process = try? ChildProcess.launch(ChildProcessSpec(executable: executable, arguments: arguments)) else { return nil }
        let reader = await withTaskCancellationHandler {
            var reader = HitReader(ripgrep: ripgrep, limit: collectionLimit)
            for await chunk in process.stdout where !reader.isFull {
                reader.append(chunk)
                if reader.isFull { process.terminate() }
            }
            reader.finish()
            return reader
        } onCancel: {
            process.terminate()
        }
        let status = (try? await process.exitCode) ?? 0
        return Task.isCancelled ? nil : (reader.hits, reader.isFull ? 0 : status)
    }
}

/// Splits a search tool's output into lines as it arrives and parses each into a hit, up to `limit` hits.
nonisolated struct HitReader {
    let ripgrep: Bool
    let limit: Int
    private(set) var hits: [SearchHit] = []
    private var pending = Data()

    init(ripgrep: Bool, limit: Int) {
        self.ripgrep = ripgrep
        self.limit = limit
    }

    var isFull: Bool { hits.count >= limit }

    mutating func append(_ chunk: Data) {
        pending.append(chunk)
        var start = pending.startIndex
        while !isFull, let newline = pending[start...].firstIndex(of: 0x0A) {
            parse(pending[start..<newline])
            start = newline + 1
        }
        pending = isFull ? Data() : Data(pending[start...])
    }

    /// The last line, when the output did not end with a newline.
    mutating func finish() {
        if !isFull, !pending.isEmpty { parse(pending) }
        pending = Data()
    }

    private mutating func parse(_ line: Data) {
        if let hit = RemoteSearch.parse(line: Data(line), ripgrep: ripgrep) {
            hits.append(SearchHit(path: hit.path, line: hit.line, text: hit.text))
        }
    }
}
