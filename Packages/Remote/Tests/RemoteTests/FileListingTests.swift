import Core
import Foundation
import Testing
@testable import Remote

struct FileListingTests {
    @Test func scriptsQuoteTheRootAndSkipNoise() {
        var tools = RemoteTools()
        tools.rg = true
        #expect(FileListing.script(root: "/home/c/it's", tools: tools) == #"rg --files --hidden --no-messages --glob '!.git' --glob '!node_modules' -- '/home/c/it'\''s' | head -n 50000"#)
        tools.rg = false
        #expect(FileListing.script(root: "/r", tools: tools).hasPrefix("find '/r' \\( -name .git -o -name node_modules \\) -prune -o -type f -print"))
    }

    @Test(arguments: [true, false])
    func listsLocalFilesWithEitherTool(useRipgrep: Bool) async throws {
        let ripgrep = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        if useRipgrep, ripgrep == nil { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-list-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for directory in ["src/deep", ".git/objects", "node_modules/pkg", "space dir"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(directory)", withIntermediateDirectories: true)
        }
        for file in ["src/deep/a.swift", ".git/objects/x", "node_modules/pkg/index.js", "space dir/b c.md", ".env"] {
            try "x".write(toFile: "\(root)/\(file)", atomically: true, encoding: .utf8)
        }
        let listed = await FileListing.listLocally(root: root, ripgrep: useRipgrep ? ripgrep : nil)
        let relative = Set(listed.map { String($0.dropFirst(root.count + 1)) })
        #expect(relative == ["src/deep/a.swift", "space dir/b c.md", ".env"], "\(relative)")
    }

    /// Without rg, a git work tree is listed by git: ignored build products left out, untracked files in, a tracked
    /// file deleted from disk out, node_modules out; a folder its repository ignores falls back to find. The remote
    /// script does the same, run here by sh.
    @Test func withoutRipgrepAGitWorkTreeLeavesIgnoredFilesOut() async throws {
        let git = try #require(FileListing.localGit)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-gitlist-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for directory in ["src", ".build/debug", "node_modules/pkg", "sp ace"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(directory)", withIntermediateDirectories: true)
        }
        try ".build/\n*.log\n".write(toFile: "\(root)/.gitignore", atomically: true, encoding: .utf8)
        for file in ["src/a.swift", "src/gone.swift", ".build/debug/app.o", "node_modules/pkg/i.js", "sp ace/b c.md", "run.log", "new.txt"] {
            try "x".write(toFile: "\(root)/\(file)", atomically: true, encoding: .utf8)
        }
        func run(_ arguments: [String]) async throws {
            let process = try ChildProcess.launch(ChildProcessSpec(executable: git, arguments: ["-C", root] + arguments))
            #expect(try await process.exitCode == 0)
        }
        try await run(["init", "-q"])
        try await run(["add", ".gitignore", "src/a.swift", "src/gone.swift"])
        try FileManager.default.removeItem(atPath: "\(root)/src/gone.swift")
        let expected: Set<String> = [".gitignore", "src/a.swift", "sp ace/b c.md", "new.txt"]

        let listed = await FileListing.listLocally(root: root, ripgrep: nil)
        #expect(Set(listed.map { String($0.dropFirst(root.count + 1)) }) == expected)

        var tools = RemoteTools()
        tools.git = true
        let shell = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sh", arguments: ["-c", FileListing.script(root: root, tools: tools)]))
        let output = await shell.collectStdout()
        #expect(Set(FileListing.parse(output).map { String($0.dropFirst(root.count + 1)) }) == expected, "the remote script lists the same")

        let ignored = await FileListing.listLocally(root: "\(root)/.build", ripgrep: nil)
        #expect(ignored.map { String($0.dropFirst(root.count + 1)) } == [".build/debug/app.o"], "an ignored folder opened on its own is listed by find")
    }

    /// `GLOSS_REMOTE_HOST=<alias>`: lists a throwaway directory on the host over the exec channel.
    @Test(.enabled(if: TestGates.remoteHost != nil))
    func listsFilesOnTheRemoteHost() async throws {
        let alias = try #require(TestGates.remoteHost)
        try await TestGates.withManager(serialized: false) { manager, _ in
            let connection = try await manager.connection(for: HostID.new(), alias: alias)
            let tools = try await connection.tools()
            let root = PathUtilities.join(tools.tmpdir, "gloss-list-\(UUID().uuidString.prefix(8))")
            let quoted = ShellQuote.single(root)
            _ = try await connection.exec("mkdir -p \(quoted)/src \(quoted)/.git \(quoted)/node_modules/x '\(root)/sp ace' && touch \(quoted)/src/a.rs \(quoted)/.git/HEAD \(quoted)/node_modules/x/i.js '\(root)/sp ace/b.md' \(quoted)/.env")
            let listed = try await FileListing.list(root: root, over: connection)
            _ = try await connection.exec("rm -rf -- \(quoted)")
            #expect(Set(listed.map { String($0.dropFirst(root.count + 1)) }) == ["src/a.rs", "sp ace/b.md", ".env"], "\(listed)")
        }
    }
}
