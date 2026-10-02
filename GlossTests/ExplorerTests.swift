import Core
import Foundation
import Testing
@testable import Gloss

@MainActor
struct FileNodeTests {
    func entry(_ name: String, directory: Bool = false) -> DirectoryEntry {
        DirectoryEntry(name: name, path: "/root/\(name)", kind: directory ? .directory : .file)
    }

    @Test func mergeKeepsExistingNodesAndReportsChanges() {
        let root = FileNode(hostID: .local, entry: DirectoryEntry(name: "root", path: "/root", kind: .directory), parent: nil)
        let first = root.merge(entries: [entry("a"), entry("b", directory: true), entry("c")])
        #expect(first.inserted.count == 3 && first.removed.isEmpty)
        let bNode = root.children![1]
        bNode.children = []   // pretend it was expanded
        let second = root.merge(entries: [entry("b", directory: true), entry("c"), entry("d")])
        #expect(second.inserted.map(\.name) == ["d"])
        #expect(second.removed.map(\.name) == ["a"])
        #expect(root.children![0] === bNode, "node identity survives a refresh")
        #expect(bNode.isLoaded, "a loaded directory stays loaded")
        #expect(root.children!.map(\.name) == ["b", "c", "d"])
    }

    @Test func visibleChildrenApplyDotfilesAndFilter() {
        let root = FileNode(hostID: .local, entry: DirectoryEntry(name: "root", path: "/root", kind: .directory), parent: nil)
        _ = root.merge(entries: [entry(".git", directory: true), entry("Readme.md"), entry("src", directory: true), entry("notes.txt")])
        #expect(root.visibleChildren(showDotfiles: false, filter: "").map(\.name) == ["Readme.md", "src", "notes.txt"])
        #expect(root.visibleChildren(showDotfiles: true, filter: "").count == 4)
        #expect(root.visibleChildren(showDotfiles: false, filter: "read").map(\.name) == ["Readme.md", "src"], "directories stay visible under a filter")
    }

    @Test func descendantLookup() {
        let root = FileNode(hostID: .local, entry: DirectoryEntry(name: "root", path: "/root", kind: .directory), parent: nil)
        _ = root.merge(entries: [entry("src", directory: true)])
        let src = root.children![0]
        _ = src.merge(entries: [DirectoryEntry(name: "main.swift", path: "/root/src/main.swift", kind: .file)])
        #expect(root.descendant(at: "/root/src/main.swift")?.name == "main.swift")
        #expect(root.descendant(at: "/root/src") === src)
        #expect(root.descendant(at: "/rootx") == nil)
    }
}

struct GitIgnoreServiceTests {
    @Test func reportsIgnoredNamesInsideARepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let git = try #require(GitIgnoreService.gitPath)
        let setup = Process()
        setup.executableURL = URL(fileURLWithPath: git)
        setup.arguments = ["-C", directory, "init", "-q"]
        try setup.run()
        setup.waitUntilExit()
        try "build/\n*.log\n".write(toFile: "\(directory)/.gitignore", atomically: true, encoding: .utf8)
        let ignored = await GitIgnoreService.ignoredNames(in: directory, entries: [("build", true), ("app.log", false), ("main.swift", false), (".gitignore", false)])
        #expect(ignored == ["build", "app.log"])
    }

    @Test func nothingIgnoredOutsideARepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-nogit-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let ignored = await GitIgnoreService.ignoredNames(in: directory, entries: [("a", false), ("b", true)])
        #expect(ignored.isEmpty)
    }
}
