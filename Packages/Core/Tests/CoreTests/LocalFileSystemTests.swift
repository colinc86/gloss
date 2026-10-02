import Foundation
import Testing
@testable import Core

struct LocalFileSystemTests {
    func withTemporaryDirectory<T>(_ body: (String, LocalFileSystem) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-fs-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        return try await body(directory, LocalFileSystem(deleteBehavior: .permanent))
    }

    @Test func listsWithKindsAndHiddenFlag() async throws {
        try await withTemporaryDirectory { directory, fs in
            try "hello".write(toFile: "\(directory)/b.txt", atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(atPath: "\(directory)/a dir", withIntermediateDirectories: true)
            try "x".write(toFile: "\(directory)/.hidden", atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: "\(directory)/link", withDestinationPath: "\(directory)/a dir")
            try FileManager.default.createSymbolicLink(atPath: "\(directory)/dangling", withDestinationPath: "\(directory)/nope")
            let entries = try await fs.list(directory)
            #expect(entries.map(\.name) == [".hidden", "a dir", "b.txt", "dangling", "link"])
            let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
            #expect(byName["a dir"]?.kind == .directory)
            #expect(byName["b.txt"]?.kind == .file)
            #expect(byName["b.txt"]?.size == 5)
            #expect(byName[".hidden"]?.isHidden == true)
            #expect(byName["link"]?.kind == .symlink)
            #expect(byName["link"]?.targetKind == .directory)
            #expect(byName["link"]?.isDirectoryLike == true)
            #expect(byName["dangling"]?.targetKind == nil)
            await #expect(throws: FileSystemError.notFound("\(directory)/missing")) {
                _ = try await fs.list("\(directory)/missing")
            }
        }
    }

    @Test func atomicWritePreservesModeAndReplacesContent() async throws {
        try await withTemporaryDirectory { directory, fs in
            let path = "\(directory)/script.sh"
            try "old".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            let original = try await fs.stat(path)
            #expect(original.mode == 0o755)
            let written = try await fs.writeAtomically(Data("new content".utf8), to: path, preservingModeFrom: original)
            #expect(written.mode == 0o755)
            #expect(written.size == 11)
            #expect(try await fs.read(path) == Data("new content".utf8))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasPrefix(".cc-") }
            #expect(leftovers.isEmpty)

            let fresh = "\(directory)/new.txt"
            let created = try await fs.writeAtomically(Data("x".utf8), to: fresh, preservingModeFrom: nil)
            #expect(created.mode == 0o644)
        }
    }

    @Test func conflictCheckUsesSizeMtimeThenHash() async throws {
        try await withTemporaryDirectory { directory, fs in
            let path = "\(directory)/doc.md"
            try "version one".write(toFile: path, atomically: true, encoding: .utf8)
            let (data, fingerprint) = try await fs.readWithFingerprint(path)
            #expect(data == Data("version one".utf8))
            #expect(fingerprint.hash == Data("version one".utf8).sha256Hex)
            #expect(try await fs.checkForChanges(at: path, since: fingerprint) == .unchanged)

            // Same size, same content, but a new mtime: the hash says unchanged.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: path)
            #expect(try await fs.checkForChanges(at: path, since: fingerprint) == .unchanged)

            try await Task.sleep(for: .milliseconds(5))   // past the millisecond the fingerprint was taken in
            try "version two".write(toFile: path, atomically: true, encoding: .utf8)
            guard case .changed(let current, let newFingerprint) = try await fs.checkForChanges(at: path, since: fingerprint) else {
                Issue.record("expected a change"); return
            }
            #expect(current == Data("version two".utf8))
            #expect(newFingerprint.hash == Data("version two".utf8).sha256Hex)
        }
    }

    @Test func directoryRenameDelete() async throws {
        try await withTemporaryDirectory { directory, fs in
            try await fs.makeDirectory("\(directory)/a/b/c")
            #expect(try await fs.stat("\(directory)/a/b/c").kind == .directory)
            try "x".write(toFile: "\(directory)/a/f.txt", atomically: true, encoding: .utf8)
            try await fs.rename("\(directory)/a/f.txt", to: "\(directory)/a/g.txt")
            #expect(try await fs.list("\(directory)/a").map(\.name) == ["b", "g.txt"])
            try "y".write(toFile: "\(directory)/a/h.txt", atomically: true, encoding: .utf8)
            await #expect(throws: FileSystemError.alreadyExists("\(directory)/a/h.txt")) {
                try await fs.rename("\(directory)/a/g.txt", to: "\(directory)/a/h.txt")
            }
            try await fs.delete("\(directory)/a/b")
            try await fs.delete("\(directory)/a/g.txt")
            #expect(try await fs.list("\(directory)/a").map(\.name) == ["h.txt"])
        }
    }

    @Test func watcherReportsCreatedFileAndStopsOnCancel() async throws {
        try await withTemporaryDirectory { directory, fs in
            let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
            let stream = fs.watch(directory)
            let collector = Task { () -> [String] in
                var seen: [String] = []
                for await event in stream {
                    if case .changed(let paths) = event { seen.append(contentsOf: paths) }
                    if seen.contains(where: { $0.hasSuffix("/created.txt") }) { break }
                }
                return seen
            }
            defer { collector.cancel() }
            try await Task.sleep(for: .milliseconds(300))
            try "hi".write(toFile: "\(directory)/created.txt", atomically: true, encoding: .utf8)
            let result = await withTaskGroup(of: [String]?.self) { group in
                group.addTask { await collector.value }
                group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
            let seen = try #require(result, "watcher produced no event within 5 seconds")
            let reported = seen.filter { $0.hasSuffix("/created.txt") }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            #expect(reported.contains(resolved + "/created.txt"), "saw \(seen)")
        }
    }

    @Test func pathUtilities() {
        #expect(PathUtilities.join("/a", "b") == "/a/b")
        #expect(PathUtilities.join("/a/", "b") == "/a/b")
        #expect(PathUtilities.parent(of: "/a/b") == "/a")
        #expect(PathUtilities.parent(of: "/a") == "/")
        #expect(PathUtilities.relative("/a/b/c.md", to: "/a") == "b/c.md")
        #expect(PathUtilities.relative("/x/c.md", to: "/a") == "/x/c.md")
    }
}
