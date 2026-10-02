import Core
import Foundation
import Observation
import OSLog

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

    func search(in root: String) {
        cancel()
        let pattern = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            hits = []
            return
        }
        isSearching = true
        truncated = false
        task = Task { [weak self] in
            let results = await Self.run(pattern: pattern, root: root)
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

    nonisolated private static func run(pattern: String, root: String) async -> [SearchHit] {
        await Task.detached(priority: .userInitiated) {
            if let rg = ripgrepPath {
                return runRipgrep(rg, pattern: pattern, root: root)
            }
            return runGrep(pattern: pattern, root: root)
        }.value
    }

    nonisolated private static func runRipgrep(_ rg: String, pattern: String, root: String) -> [SearchHit] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rg)
        process.arguments = ["--json", "-n", "--no-messages", "--max-count", "200", "--max-filesize", "2M", "-e", pattern, "--", root]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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

    nonisolated private static func runGrep(pattern: String, root: String) -> [SearchHit] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-rnI", "--exclude-dir=.git", "-e", pattern, "--", root]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]) else { return nil }
            return SearchHit(path: String(parts[0]), line: number, text: String(parts[2]))
        }
    }
}
