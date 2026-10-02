import Foundation
import Testing
@testable import Gloss

@MainActor
struct ContentSearchTests {
    @Test func findsMatchesWithLineNumbers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-search-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(directory)/sub", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "alpha\nneedle one\ngamma\n".write(toFile: "\(directory)/a.txt", atomically: true, encoding: .utf8)
        try "needle two\n".write(toFile: "\(directory)/sub/b.md", atomically: true, encoding: .utf8)
        let model = ContentSearchModel()
        model.query = "needle"
        model.search(in: directory)
        for _ in 0..<100 where model.isSearching { try await Task.sleep(for: .milliseconds(30)) }
        let hits = model.hits.sorted { $0.path < $1.path }
        #expect(hits.map(\.line) == [2, 1])
        #expect(hits.map { ($0.path as NSString).lastPathComponent } == ["a.txt", "b.md"])
        #expect(hits.first?.text == "needle one")
        #expect(model.groupedHits.count == 2)
        model.query = "   "
        model.search(in: directory)
        #expect(model.hits.isEmpty)
    }
}
