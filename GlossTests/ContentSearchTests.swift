import Core
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

    private func runSearch(_ model: ContentSearchModel, _ query: String, in directory: String, regex: Bool = false) async throws -> [String] {
        model.query = query
        model.isRegex = regex
        model.search(in: directory)
        for _ in 0..<100 where model.isSearching { try await Task.sleep(for: .milliseconds(30)) }
        return model.hits.map(\.text).sorted()
    }

    /// Queries are literal unless regex is on (typing `foo(` used to be an invalid regex showing no matches), case is
    /// ignored unless the query has a capital, and an invalid regex says so.
    @Test func literalByDefaultSmartCaseAndRegexErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-search2-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "call foo(1)\nlet a: [String] = []\nFOO bar\nfoxo\n".write(toFile: "\(directory)/a.swift", atomically: true, encoding: .utf8)
        let model = ContentSearchModel()
        #expect(try await runSearch(model, "foo(", in: directory) == ["call foo(1)"], "parentheses are plain text")
        #expect(try await runSearch(model, "[String]", in: directory) == ["let a: [String] = []"])
        #expect(try await runSearch(model, "foo", in: directory) == ["FOO bar", "call foo(1)"], "lowercase ignores case")
        #expect(try await runSearch(model, "FOO", in: directory) == ["FOO bar"], "a capital makes it case-sensitive")
        #expect(try await runSearch(model, "fo.o", in: directory, regex: true) == ["foxo"])
        #expect(model.errorMessage == nil)
        #expect(try await runSearch(model, "foo(", in: directory, regex: true).isEmpty)
        #expect(model.errorMessage == "Not a valid regular expression")
        // An unreadable file makes rg and grep exit 2 too; a valid search that finds nothing is just "no matches".
        try "secret\n".write(toFile: "\(directory)/locked.txt", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: "\(directory)/locked.txt")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(directory)/locked.txt") }
        #expect(try await runSearch(model, "nothing.here", in: directory, regex: true).isEmpty)
        #expect(model.errorMessage == nil, "an unreadable file is not a bad pattern")
        #expect(try await runSearch(model, "nothing here", in: directory).isEmpty)
        #expect(model.errorMessage == nil)
    }
}

@MainActor
struct QuickOpenTests {
    @Test func listsRanksAndSelectsFilesUnderTheRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-quick-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/App", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/Notes", withIntermediateDirectories: true)
        for file in ["App/AppModel.swift", "Notes/NotesPanelModel.swift", "README.md"] {
            try "x".write(toFile: "\(root)/\(file)", atomically: true, encoding: .utf8)
        }
        let quick = QuickOpenModel()
        quick.present(root: root, hostID: .local, connection: nil)
        #expect(quick.isPresented && quick.isLoading)
        for _ in 0..<100 where quick.isLoading || quick.results.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(quick.results.first == "README.md", "an empty query lists short paths first")
        quick.query = "npm"
        for _ in 0..<100 where quick.results.first != "Notes/NotesPanelModel.swift" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(quick.results.first == "Notes/NotesPanelModel.swift")
        #expect(quick.selectedPath == "\(root)/Notes/NotesPanelModel.swift")
        quick.query = "model"
        for _ in 0..<100 where quick.results.count != 2 { try await Task.sleep(for: .milliseconds(20)) }
        quick.moveSelection(by: 5)
        #expect(quick.selectedIndex == 1, "selection stops at the last result")
        quick.moveSelection(by: -9)
        #expect(quick.selectedIndex == 0)
        quick.dismiss()
        #expect(!quick.isPresented)

        // Return pressed right after typing, before the ranking finished, opens the top result once it arrives.
        var opened: [String] = []
        quick.onOpen = { _, path in opened.append(path) }
        quick.present(root: root, hostID: .local, connection: nil)
        quick.query = "appmodel"
        quick.submit()
        for _ in 0..<100 where opened.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(opened == ["\(root)/App/AppModel.swift"])
        #expect(!quick.isPresented)
    }

    @Test func returnOpensTheSelectedResultNotTheTopOne() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-quick-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/data", withIntermediateDirectories: true)
        for file in ["src/trail.swift", "data/route.json"] { try "x".write(toFile: "\(root)/\(file)", atomically: true, encoding: .utf8) }
        let quick = QuickOpenModel()
        var opened: [String] = []
        quick.onOpen = { _, path in opened.append(path) }
        quick.present(root: root, hostID: .local, connection: nil)
        for _ in 0..<100 where quick.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        quick.query = "tr"
        for _ in 0..<100 where quick.isRanking || quick.results.count != 2 { try await Task.sleep(for: .milliseconds(20)) }
        quick.moveSelection(by: 1)
        let chosen = try #require(quick.selectedPath)
        quick.query = "tr"   // the field writes its text back on Return
        quick.submit()
        #expect(opened == [chosen], "the arrow-key selection survives Return")
    }

    /// A remote root whose host is not connected is never listed on this Mac.
    @Test func aRemoteRootWithoutAConnectionShowsAnError() {
        let quick = QuickOpenModel()
        quick.present(root: NSHomeDirectory(), hostID: HostID.new(), connection: nil)
        #expect(quick.errorMessage == "Not connected to this folder's host")
        #expect(!quick.isLoading && quick.results.isEmpty)
    }
}
