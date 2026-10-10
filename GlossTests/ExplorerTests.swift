import Core
import Foundation
import Testing
import UniformTypeIdentifiers
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
        let bNode = root.children!.first { $0.name == "b" }!
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
        #expect(root.visibleChildren(showDotfiles: false, filter: "").map(\.name) == ["src", "notes.txt", "Readme.md"], "folders first, then names")
        #expect(root.visibleChildren(showDotfiles: true, filter: "").count == 4)
        #expect(root.visibleChildren(showDotfiles: false, filter: "read").map(\.name) == ["src", "Readme.md"], "directories stay visible under a filter")
        #expect(root.visibleChildren(showDotfiles: false, filter: " notes ").map(\.name) == ["src", "notes.txt"], "spaces around it aside")
        _ = root.merge(entries: [entry("src", directory: true), entry("Résumé.md"), DirectoryEntry(name: "CP-7.md", path: "/root/CP-7.md", kind: .file, title: "Move the legend")])
        #expect(root.visibleChildren(showDotfiles: false, filter: "resume").map(\.name) == ["src", "Résumé.md"], "accents aside, as Open Quickly")
        #expect(root.visibleChildren(showDotfiles: false, filter: "legend").map(\.name) == ["src", "CP-7.md"], "an issue by the summary its row shows")
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

@MainActor
final class RecordingTreeDelegate: ExplorerTreeDelegate {
    var revealed: [[String]] = []
    func treeDidReplaceRoot() {}
    func treeDidReload(_ node: FileNode) {}
    func treeDidChangeFilters() {}
    func treeReveal(_ chain: [FileNode]) { revealed.append(chain.map(\.name)) }
    func treeDidChangeNoteMarks() {}
}

@MainActor
struct ExplorerRevealTests {
    @Test func revealsAFileThroughUnlistedAndHiddenDirectories() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-reveal-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: "\(base)/proj/src/.config/deep", withIntermediateDirectories: true)
        try "x".write(toFile: "\(base)/proj/src/.config/deep/file.txt", atomically: true, encoding: .utf8)
        try "y".write(toFile: "\(base)/proj/README.md", atomically: true, encoding: .utf8)
        let store = NoteStore(database: try AppDatabase.inMemory())
        let explorer = ExplorerModel(noteStore: store)
        let local = LocalFileSystem(deleteBehavior: .permanent)
        explorer.fileSystemProvider = { _ in local }
        let delegate = RecordingTreeDelegate()
        explorer.treeDelegate = delegate
        await explorer.openRoot(hostID: .local, path: base)
        await explorer.openRoot(hostID: .local, path: "\(base)/proj")
        await explorer.openRoot(hostID: .local, path: base)   // the outer root is selected again
        #expect(explorer.showDotfiles == false)

        let found = await explorer.reveal(hostID: .local, path: "\(base)/proj/src/.config/deep/file.txt")
        #expect(found)
        #expect(explorer.selectedTab?.path == "\(base)/proj", "the deepest root containing the file is chosen")
        #expect(delegate.revealed.last == ["proj", "src", ".config", "deep", "file.txt"])
        #expect(explorer.showDotfiles, "a hidden directory on the way is shown so the file is reachable")

        #expect(await explorer.reveal(hostID: .local, path: "/elsewhere/file.txt") == false, "no root contains it")
        explorer.filter = "readme"
        #expect(await explorer.reveal(hostID: .local, path: "\(base)/proj/src/.config/deep/file.txt"))
        #expect(explorer.filter.isEmpty, "a filter hiding the target is cleared so the row exists")
        let missing = await explorer.reveal(hostID: .local, path: "\(base)/proj/src/gone.txt")
        #expect(!missing && delegate.revealed.last == ["proj", "src"], "a missing file reveals as far as it exists")
        explorer.stopWatching()
    }
}

@MainActor
struct ExplorerRootTabTests {
    @Test func oneFolderOpensOneTabWhateverItsSpellingOrTiming() async throws {
        // The temporary directory lives under `/var`, a symlink to `/private/var`.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gloss-tabs-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let other = base.hasPrefix("/private/") ? String(base.dropFirst("/private".count)) : "/private" + base
        let explorer = ExplorerModel(noteStore: NoteStore(database: try AppDatabase.inMemory()))
        let local = LocalFileSystem(deleteBehavior: .permanent)
        explorer.fileSystemProvider = { _ in local }
        await explorer.openRoot(hostID: .local, path: base)
        await explorer.openRoot(hostID: .local, path: other)
        await explorer.openRoot(hostID: .local, path: base + "/")
        #expect(explorer.tabs.count == 1, "symlinked and trailing-slash spellings reuse the tab")
        explorer.closeTab(explorer.tabs[0].id)
        // Two opens racing past the existence check while the host answers.
        async let first: Void = explorer.openRoot(hostID: .local, path: base)
        async let second: Void = explorer.openRoot(hostID: .local, path: other)
        _ = await (first, second)
        #expect(explorer.tabs.count == 1, "concurrent opens of one folder make one tab")
        #expect(Set(explorer.recentRoots.map { ExplorerModel.canonical($0.path, hostID: .local) }).count == explorer.recentRoots.count, "recents list each folder once")
        explorer.stopWatching()
    }
}

@MainActor
struct FileTreeOrderTests {
    @Test func foldersComeFirstThenNamesInFinderOrder() {
        func entry(_ name: String, _ kind: FileKind, target: FileKind? = nil) -> DirectoryEntry {
            DirectoryEntry(name: name, path: "/r/\(name)", kind: kind, targetKind: target)
        }
        let root = FileNode(hostID: .local, entry: entry("r", .directory), parent: nil)
        // A remote listing arrives in whatever order the server sends.
        _ = root.merge(entries: [
            entry("readme.md", .file), entry("src", .directory), entry("File10.txt", .file), entry("Docs", .directory),
            entry("file2.txt", .file), entry("linked", .symlink, target: .directory), entry(".env", .file), entry("apps", .directory),
        ])
        #expect(root.children?.map(\.name) == ["apps", "Docs", "linked", "src", ".env", "file2.txt", "File10.txt", "readme.md"])
    }
}

@MainActor
struct ExplorerNoteMarkTests {
    private func note(_ document: Core.Document, _ color: NoteColor, _ state: NoteState, waiting: Bool = false) -> Note {
        Note(id: .new(), documentID: document.id, anchor: .wholeFile, body: "x", state: state, color: color,
             createdAt: Date(), updatedAt: Date(), waitingOnUser: waiting)
    }

    @Test func marksCountOpenWorkByFileAndFolder() throws {
        let explorer = ExplorerModel(noteStore: NoteStore(database: try AppDatabase.inMemory()))
        let readme = Core.Document(id: .new(), hostID: .local, path: "/private/tmp/p/README.md", kind: .markdown, fingerprint: Fingerprint())
        let swift = Core.Document(id: .new(), hostID: .local, path: "/private/tmp/p/src/a.swift", kind: .code, fingerprint: Fingerprint())
        let done = Core.Document(id: .new(), hostID: .local, path: "/private/tmp/p/done.txt", kind: .text, fingerprint: Fingerprint())
        explorer.updateNoteMarks([
            DocumentNotes(document: readme, notes: [note(readme, .green, .draft), note(readme, .yellow, .sent), note(readme, .green, .draft),
                                                    note(readme, .blue, .resolved)]),
            DocumentNotes(document: swift, notes: [note(swift, .pink, .sent, waiting: true)]),
            DocumentNotes(document: done, notes: [note(done, .blue, .resolved)]),
        ])
        let root = FileNode(hostID: .local, entry: DirectoryEntry(name: "p", path: "/tmp/p", kind: .directory), parent: nil)
        let readmeNode = FileNode(hostID: .local, entry: DirectoryEntry(name: "README.md", path: "/tmp/p/README.md", kind: .file), parent: root)
        // `/private/tmp` documents land on `/tmp` rows.
        #expect(explorer.mark(for: readmeNode) == NoteMark(count: 3, colors: [.green, .yellow], needsAttention: false), "resolved notes do not count; most used colour first")
        let swiftNode = FileNode(hostID: .local, entry: DirectoryEntry(name: "a.swift", path: "/tmp/p/src/a.swift", kind: .file), parent: root)
        #expect(explorer.mark(for: swiftNode)?.needsAttention == true, "a question from the agent is open work")
        let doneNode = FileNode(hostID: .local, entry: DirectoryEntry(name: "done.txt", path: "/tmp/p/done.txt", kind: .file), parent: root)
        #expect(explorer.mark(for: doneNode) == nil)
        #expect(explorer.folderCount(for: root) == 4)
        let src = FileNode(hostID: .local, entry: DirectoryEntry(name: "src", path: "/tmp/p/src", kind: .directory), parent: root)
        #expect(explorer.folderCount(for: src) == 1)
        let remote = FileNode(hostID: HostID(rawValue: "asus"), entry: DirectoryEntry(name: "p", path: "/tmp/p", kind: .directory), parent: nil)
        #expect(explorer.folderCount(for: remote) == 0, "marks are per host")
    }
}

@MainActor
struct ExplorerRevealAliasTests {
    @Test func revealFindsAFileThroughThePrivateAlias() async throws {
        // NSTemporaryDirectory lives under /var (a link to /private/var); open the root one way, reveal the other.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gloss-alias-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base + "/src", withIntermediateDirectories: true)
        try "x".write(toFile: base + "/src/a.swift", atomically: true, encoding: .utf8)
        let explorer = ExplorerModel(noteStore: NoteStore(database: try AppDatabase.inMemory()))
        let local = LocalFileSystem(deleteBehavior: .permanent)
        explorer.fileSystemProvider = { _ in local }
        let delegate = RecordingTreeDelegate()
        explorer.treeDelegate = delegate
        let privateSpelling = base.hasPrefix("/private/") ? base : "/private" + base
        await explorer.openRoot(hostID: .local, path: privateSpelling)
        #expect(await explorer.reveal(hostID: .local, path: privateSpelling + "/src/a.swift"))
        #expect(delegate.revealed.last?.suffix(2) == ["src", "a.swift"])
        #expect(await explorer.reveal(hostID: .local, path: privateSpelling + "/src"), "folders reveal too")
        explorer.stopWatching()
    }
}

struct RootSpellingTests {
    @Test func pathsInsideARootAreRewrittenToItsSpelling() {
        #expect(ExplorerModel.inRootSpelling("/private/tmp/p/src/a.swift", root: "/tmp/p", hostID: .local) == "/tmp/p/src/a.swift")
        #expect(ExplorerModel.inRootSpelling("/tmp/p", root: "/tmp/p", hostID: .local) == "/tmp/p")
        #expect(ExplorerModel.inRootSpelling("/tmp/p2/a", root: "/tmp/p", hostID: .local) == nil, "a shared prefix is not inside")
        #expect(ExplorerModel.inRootSpelling("/private/tmp/p/a", root: "/tmp/p", hostID: HostID(rawValue: "asus")) == nil, "remote paths are taken literally")
        #expect(ExplorerModel.inRootSpelling("/home/me/p/a", root: "/home/me/p", hostID: HostID(rawValue: "asus")) == "/home/me/p/a")
    }
}

struct NoteDisplayStateTests {
    @Test func aQuestionFromTheAgentIsDrawnLikeOpenWork() {
        func note(_ state: NoteState, waiting: Bool = false, unsent: Bool = false) -> Note {
            Note(id: .new(), documentID: .new(), anchor: .wholeFile, body: "x", state: state, color: .blue, createdAt: Date(), updatedAt: Date(),
                 waitingOnUser: waiting, hasUnsentFollowUps: unsent)
        }
        #expect(note(.sent, waiting: true).displayState == .draft, "the user's turn stands out")
        #expect(note(.sent, unsent: true).displayState == .draft, "so does a follow-up waiting to be sent")
        #expect(note(.resolved).displayState == .resolved)
        #expect(note(.sent).displayState == .sent)
        #expect(note(.orphaned, waiting: true).displayState == .orphaned)
    }
}

@MainActor
struct ActiveDocumentPathTests {
    @Test func foldersOnThePathHoldTheOpenDocument() throws {
        let explorer = ExplorerModel(noteStore: NoteStore(database: try AppDatabase.inMemory()))
        explorer.setActiveDocument(hostID: .local, path: "/tmp/gloss-active/images/landscape.jpg")
        func folder(_ path: String) -> FileNode {
            FileNode(hostID: .local, entry: DirectoryEntry(name: (path as NSString).lastPathComponent, path: path, kind: .directory), parent: nil)
        }
        #expect(explorer.holdsActiveDocument(folder("/tmp/gloss-active")))
        #expect(explorer.holdsActiveDocument(folder("/tmp/gloss-active/images")))
        #expect(!explorer.holdsActiveDocument(folder("/tmp/gloss-active/imag")))
        #expect(!explorer.holdsActiveDocument(folder("/tmp/gloss-active/data")))
        explorer.setActiveDocument(hostID: nil, path: nil)
        #expect(!explorer.holdsActiveDocument(folder("/tmp/gloss-active")))
    }
}


/// A file system whose listing of one folder takes a while, as a slow host's does.
private struct SlowListing: FileSystemProvider {
    let local = LocalFileSystem(deleteBehavior: .permanent)
    let slowFolder: String
    let delay: Duration
    var hostID: HostID { .local }
    func list(_ directory: String) async throws -> [DirectoryEntry] {
        if directory == slowFolder { try await Task.sleep(for: delay) }
        return try await local.list(directory)
    }
    func stat(_ path: String) async throws -> FileAttributes { try await local.stat(path) }
    func read(_ path: String) async throws -> Data { try await local.read(path) }
    func writeAtomically(_ data: Data, to path: String, preservingModeFrom original: FileAttributes?) async throws -> FileAttributes {
        try await local.writeAtomically(data, to: path, preservingModeFrom: original)
    }
    func makeDirectory(_ path: String) async throws { try await local.makeDirectory(path) }
    func rename(_ path: String, to newPath: String) async throws { try await local.rename(path, to: newPath) }
    func delete(_ path: String) async throws { try await local.delete(path) }
    func watch(_ path: String) -> AsyncStream<FileSystemEvent> { local.watch(path) }
}

@MainActor
struct ExplorerSlowRevealTests {
    /// Revealing a file inside a folder whose listing is already under way waits for it, however long the host
    /// takes: after a fixed 5 s the reveal used to stop at that folder.
    @Test func aRevealWaitsForASlowListing() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-slow-reveal-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(base)/src", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try "x".write(toFile: "\(base)/src/deep.txt", atomically: true, encoding: .utf8)
        let explorer = ExplorerModel(noteStore: NoteStore(database: try AppDatabase.inMemory()))
        let slow = SlowListing(slowFolder: "\(base)/src", delay: .seconds(6))
        explorer.fileSystemProvider = { _ in slow }
        await explorer.openRoot(hostID: .local, path: base)
        let src = try #require(explorer.selectedTab?.node.children?.first { $0.name == "src" })
        let expanding = Task { await explorer.loadChildren(of: src) }   // the user expanded it just now
        try await Task.sleep(for: .milliseconds(100))
        #expect(src.isLoading)
        let found = await explorer.reveal(hostID: .local, path: "\(base)/src/deep.txt")
        await expanding.value
        #expect(found, "the reveal reached the file once the folder had listed")
    }
}

struct DeleteConfirmationTests {
    @Test func aRemoteFolderSaysItsContentsGoForGoodAndWhere() {
        let folder = ExplorerModel.deleteConfirmation(name: "build", isDirectory: true, hostName: "devbox")
        #expect(folder.message == "Delete the folder \"build\" and everything in it on devbox?")
        #expect(folder.information.contains("can't be undone") && folder.button == "Delete")
        #expect(ExplorerModel.deleteConfirmation(name: "a.txt", isDirectory: false, hostName: "devbox").message == "Delete \"a.txt\" on devbox?")
    }

    @Test func aLocalItemGoesToTheTrash() {
        let folder = ExplorerModel.deleteConfirmation(name: "build", isDirectory: true, hostName: nil)
        #expect(folder.message == "Move the folder \"build\" and its contents to the Trash?")
        #expect(folder.button == "Move to Trash")
        #expect(ExplorerModel.deleteConfirmation(name: "a.txt", isDirectory: false, hostName: nil).message == "Move \"a.txt\" to the Trash?")
    }
}

struct DuplicateTests {
    /// A copy already on disk, whether or not the tree has listed it, is skipped rather than written over.
    @Test func aDuplicateNeverWritesOverAFileAlreadyThere() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-duplicate-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "original".write(toFile: "\(root)/a.txt", atomically: true, encoding: .utf8)
        try "keep me".write(toFile: "\(root)/a copy.txt", atomically: true, encoding: .utf8)
        let fileSystem = LocalFileSystem(deleteBehavior: .permanent)
        let made = try await ExplorerModel.duplicate("\(root)/a.txt", in: root, using: fileSystem)
        #expect(made == "\(root)/a copy 2.txt")
        #expect(try String(contentsOfFile: "\(root)/a copy.txt", encoding: .utf8) == "keep me")
        #expect(try String(contentsOfFile: made, encoding: .utf8) == "original")
        try "plain".write(toFile: "\(root)/Makefile", atomically: true, encoding: .utf8)
        #expect(try await ExplorerModel.duplicate("\(root)/Makefile", in: root, using: fileSystem) == "\(root)/Makefile copy")
    }
}

struct FreeNameTests {
    @Test func aNewItemIsOfferedANameNotTaken() {
        #expect(ExplorerModel.freeName("untitled.txt", among: ["a.md"], isFolder: false) == "untitled.txt")
        #expect(ExplorerModel.freeName("untitled.txt", among: ["untitled.txt", "Untitled 2.txt"], isFolder: false) == "untitled 3.txt", "case is ignored, as on the Mac")
        #expect(ExplorerModel.freeName("untitled folder", among: ["untitled folder"], isFolder: true) == "untitled folder 2")
        #expect(ExplorerModel.freeName("v1.2", among: ["v1.2"], isFolder: true) == "v1.2 2", "a folder's dot is not an extension")
    }
}

struct RemoteIconTests {
    /// A file that isn't on this Mac shows its type's icon, as a local one does, rather than a blank page.
    @Test func aRemoteFileShowsItsTypesIcon() {
        #expect(FileCellView.iconType(name: "main.swift", isDirectory: false) == UTType.swiftSource)
        #expect(FileCellView.iconType(name: "photo.PNG", isDirectory: false) == .png)
        #expect(FileCellView.iconType(name: "src", isDirectory: true) == .folder)
        #expect(FileCellView.iconType(name: "Makefile", isDirectory: false) == .data)
    }
}
