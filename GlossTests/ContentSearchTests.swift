import Core
import Remote
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
        // A colon is part of a name (grep's own output separates with one).
        try FileManager.default.createDirectory(atPath: "\(directory)/x:y", withIntermediateDirectories: true)
        try "intro\nneedle: three\n".write(toFile: "\(directory)/x:y/notes 10:30.md", atomically: true, encoding: .utf8)
        let model = ContentSearchModel()
        model.query = "needle"
        model.search(in: directory)
        for _ in 0..<100 where model.isSearching { try await Task.sleep(for: .milliseconds(30)) }
        let hits = model.hits.sorted { $0.path < $1.path }
        #expect(hits.map(\.line) == [2, 1, 2])
        #expect(hits.map { ($0.path as NSString).lastPathComponent } == ["a.txt", "b.md", "notes 10:30.md"])
        #expect(hits.first?.text == "needle one")
        #expect(hits.last?.text == "needle: three")
        #expect(model.groupedHits.count == 3)
        model.query = "   "
        model.search(in: directory)
        #expect(model.hits.isEmpty)
    }

    /// Results come back in the same order every time: by path as the explorer sorts, then by line.
    @Test func hitsAreInPathAndLineOrder() {
        let hits = [SearchHit(path: "/r/file10.md", line: 1, text: ""), SearchHit(path: "/r/b/a.md", line: 9, text: ""),
                    SearchHit(path: "/r/file2.md", line: 4, text: ""), SearchHit(path: "/r/b/a.md", line: 2, text: "")]
        #expect(ContentSearchModel.ordered(hits).map { "\($0.path):\($0.line)" } == ["/r/b/a.md:2", "/r/b/a.md:9", "/r/file2.md:4", "/r/file10.md:1"])
    }

    /// Output is read as it comes, a line split across chunks put back together, and reading stops at the limit.
    @Test func hitsAreReadLineByLineUpToTheLimit() {
        var reader = HitReader(ripgrep: false, limit: 3)
        reader.append(Data("/r/a.md\u{0}1:one\n/r/a.md\u{0}2:t".utf8))
        #expect(reader.hits.map(\.text) == ["one"])
        reader.append(Data("wo\nnot a hit\n/r/b.md\u{0}7:three\n/r/b.md\u{0}8:four\n".utf8))
        #expect(reader.hits.map(\.text) == ["one", "two", "three"])
        #expect(reader.isFull)
        reader.append(Data("/r/c.md\u{0}1:five\n".utf8))
        #expect(reader.hits.count == 3, "nothing more once full")

        var unterminated = HitReader(ripgrep: false, limit: 10)
        unterminated.append(Data("/r/a.md\u{0}4:last".utf8))
        unterminated.finish()
        #expect(unterminated.hits.map(\.line) == [4], "a last line without a newline still counts")
    }

    /// A word on every line of a large folder stops the tool once enough are in, and says there are more.
    @Test func aCommonWordStopsTheSearchEarly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-search-many-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let body = String(repeating: "a needle here\n", count: 150)
        for index in 0..<60 { try body.write(toFile: "\(directory)/file\(index).txt", atomically: true, encoding: .utf8) }
        let model = ContentSearchModel()
        model.query = "needle"
        model.search(in: directory)
        for _ in 0..<200 where model.isSearching { try await Task.sleep(for: .milliseconds(30)) }
        #expect(!model.isSearching)
        #expect(model.hits.count == ContentSearchModel.shownLimit)
        #expect(model.truncated)
        #expect(model.errorMessage == nil, "a stopped search is not a failed one")
        #expect(model.hits == ContentSearchModel.ordered(model.hits))
    }

    /// Without rg, a git work tree is searched through the files git lists: an ignored build folder's matches are left
    /// out, as rg leaves them; outside a work tree grep walks the folder; a bad regular expression still says so.
    @Test func withoutRipgrepIgnoredFilesAreLeftOut() async throws {
        let git = try #require(FileListing.localGit)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-search-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(directory)/build", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "build/\n".write(toFile: "\(directory)/.gitignore", atomically: true, encoding: .utf8)
        try "needle in source\n".write(toFile: "\(directory)/main.swift", atomically: true, encoding: .utf8)
        try "needle generated\n".write(toFile: "\(directory)/build/gen.swift", atomically: true, encoding: .utf8)
        func names() async -> [String] {
            await ContentSearchModel.runGrep(pattern: "needle", root: directory, regex: false, hidden: false).0.map { ($0.path as NSString).lastPathComponent }.sorted()
        }
        #expect(await names() == ["gen.swift", "main.swift"], "not a repository yet: every file")
        let initialise = try ChildProcess.launch(ChildProcessSpec(executable: git, arguments: ["-C", directory, "init", "-q"]))
        #expect(try await initialise.exitCode == 0)
        #expect(await names() == ["main.swift"], "the ignored build folder is left out")
        #expect(await ContentSearchModel.runGrep(pattern: "foo(", root: directory, regex: true, hidden: false).1, "a bad pattern says so")
        #expect(await ContentSearchModel.runGrep(pattern: "nothing.here", root: directory, regex: true, hidden: false).1 == false)
    }

    /// A match in a file that isn't UTF-8 (Latin-1, as old Windows projects have) is listed, read as the viewer reads it.
    @Test func findsMatchesInALatin1File() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-search-latin1-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try (Data("intro\ncaf".utf8) + Data([0xE9]) + Data(" needle\n".utf8)).write(to: URL(fileURLWithPath: "\(directory)/old.txt"))
        let model = ContentSearchModel()
        model.query = "needle"
        model.search(in: directory)
        for _ in 0..<100 where model.isSearching { try await Task.sleep(for: .milliseconds(30)) }
        #expect(model.hits.map(\.line) == [2])
        #expect(model.hits.first?.text == "café needle")
    }

    /// Hidden files and folders are searched when the explorer shows them, and left out when it hides them;
    /// `.git` never is.
    @Test func hiddenFilesFollowTheExplorer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-search-hidden-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(directory)/.github", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(directory)/.git", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "needle in a workflow\n".write(toFile: "\(directory)/.github/ci.yml", atomically: true, encoding: .utf8)
        try "needle in git\n".write(toFile: "\(directory)/.git/config", atomically: true, encoding: .utf8)
        try "needle in plain sight\n".write(toFile: "\(directory)/a.txt", atomically: true, encoding: .utf8)
        let model = ContentSearchModel()
        model.query = "needle"
        func names(hidden: Bool) async -> [String] {
            model.search(in: directory, hidden: hidden)
            for _ in 0..<100 where model.isSearching { try? await Task.sleep(for: .milliseconds(30)) }
            return model.hits.map { ($0.path as NSString).lastPathComponent }.sorted()
        }
        #expect(await names(hidden: false) == ["a.txt"])
        #expect(await names(hidden: true) == ["a.txt", "ci.yml"])
    }

    /// Turning Show Hidden Files on or off while results show finds them again the new way.
    @Test func togglingHiddenFilesRerunsAShowingSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-search-toggle-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(root)/.github", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "needle in a workflow\n".write(toFile: "\(root)/.github/ci.yml", atomically: true, encoding: .utf8)
        try "needle in plain sight\n".write(toFile: "\(root)/a.txt", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        for _ in 0..<100 where model.shownTab == nil { try await Task.sleep(for: .milliseconds(20)) }
        model.explorer.showDotfiles = false
        let search = model.explorer.contentSearch
        search.isVisible = true
        search.query = "needle"
        model.runContentSearch()
        for _ in 0..<100 where search.isSearching || search.hits.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(search.hits.count == 1)
        model.explorer.showDotfiles = true
        for _ in 0..<100 where search.hits.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(search.hits.count == 2, "the workflow is found once hidden files show")
        await model.shutDown()
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
    @Test func aPathInsideTheRootIsSearchedAsItsRelativePath() {
        #expect(QuickOpenModel.withinRoot("/p/app/Sources/A.swift", root: "/p/app") == "Sources/A.swift")
        #expect(QuickOpenModel.withinRoot("/p/app/Sources/A.swift:12", root: "/p/app/") == "Sources/A.swift:12", "the line stays for splitLine")
        #expect(QuickOpenModel.withinRoot("file:///p/app/My%20Notes.md", root: "/p/app") == "My Notes.md")
        #expect(QuickOpenModel.withinRoot("/p/other/A.swift", root: "/p/app") == "/p/other/A.swift", "outside the root, as typed")
        #expect(QuickOpenModel.withinRoot("/p/apple/A.swift", root: "/p/app") == "/p/apple/A.swift")
        #expect(QuickOpenModel.withinRoot("model", root: "/p/app") == "model")
    }

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

    /// A location as agents print it, `path:line`, finds the file and opens it at that line.
    @Test func aLocationOpensItsFileAtTheLine() async throws {
        #expect(QuickOpenModel.splitLine("Sources/App.swift:42") == ("Sources/App.swift", 42))
        #expect(QuickOpenModel.splitLine("App.swift:42:7") == ("App.swift", 42))
        #expect(QuickOpenModel.splitLine("App.swift").line == nil)
        #expect(QuickOpenModel.splitLine("notes 10:30") == ("notes 10", 30), "a trailing number after a colon is a line")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-quick-line-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/Notes", withIntermediateDirectories: true)
        try "x".write(toFile: "\(root)/Notes/NotesPanelModel.swift", atomically: true, encoding: .utf8)
        try "x".write(toFile: "\(root)/README.md", atomically: true, encoding: .utf8)
        let quick = QuickOpenModel()
        var opened: (String, Int)?
        quick.onOpenAtLine = { _, path, line in opened = (path, line) }
        quick.present(root: root, hostID: .local, connection: nil)
        for _ in 0..<100 where quick.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        quick.query = "NotesPanelModel.swift:12"
        for _ in 0..<100 where quick.results.first != "Notes/NotesPanelModel.swift" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(quick.results.first == "Notes/NotesPanelModel.swift")
        quick.selectedIndex = quick.rows.firstIndex { if case .file = $0 { true } else { false } } ?? 0
        quick.submit()
        #expect(opened?.0 == "\(root)/Notes/NotesPanelModel.swift" && opened?.1 == 12)

        // A file really named so is found by its name and opens without a line.
        try "x".write(toFile: "\(root)/notes 10:30", atomically: true, encoding: .utf8)
        var plain: String?
        quick.onOpen = { _, path in plain = path }
        quick.present(root: root, hostID: .local, connection: nil)
        for _ in 0..<100 where quick.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        quick.query = "notes 10:30"
        for _ in 0..<100 where quick.results.first != "notes 10:30" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(quick.results.first == "notes 10:30" && quick.resultsLine == nil)
        quick.selectedIndex = quick.rows.firstIndex { if case .file = $0 { true } else { false } } ?? 0
        quick.submit()
        #expect(plain == "\(root)/notes 10:30")
    }
}
