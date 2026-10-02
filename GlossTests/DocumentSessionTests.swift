import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

@MainActor
struct DocumentSessionTests {
    func makeFile(_ content: String, name: String = "doc.md") throws -> (String, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-session-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = "\(directory)/\(name)"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return (directory, path)
    }

    func makeSession(path: String) throws -> DocumentSession {
        let store = NoteStore(database: try AppDatabase.inMemory())
        return DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: store)
    }

    @Test func opensTextAndSavesWithFingerprint() async throws {
        let (directory, path) = try makeFile("hello\nworld\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        #expect(controller.text == "hello\nworld\n")
        #expect(session.kind == .markdown)
        #expect(session.fingerprintAtOpen?.hash == Data("hello\nworld\n".utf8).sha256Hex)
        controller.replaceAll(with: "hello\nthere\n")
        await session.save()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "hello\nthere\n")
        #expect(session.isDirty == false)
        #expect(session.conflict == nil)
        #expect(session.baseText == "hello\nthere\n")
        session.close()
    }

    @Test func detectsConflictAndMergesNonOverlappingEdits() async throws {
        let (directory, path) = try makeFile("one\ntwo\nthree\nfour\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        controller.replaceAll(with: "ONE\ntwo\nthree\nfour\n")
        try await Task.sleep(for: .milliseconds(5))
        try "one\ntwo\nthree\nFOUR\n".write(toFile: path, atomically: true, encoding: .utf8)   // the agent edited line 4
        await session.save()
        let conflict = try #require(session.conflict)
        #expect(conflict.canMerge)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "one\ntwo\nthree\nFOUR\n", "no silent overwrite")
        await session.mergeAndSave()
        #expect(session.conflict == nil)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "ONE\ntwo\nthree\nFOUR\n")
        session.close()
    }

    @Test func overlappingConflictOffersSides() async throws {
        let (directory, path) = try makeFile("a\nb\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        controller.replaceAll(with: "a-mine\nb\n")
        try await Task.sleep(for: .milliseconds(5))
        try "a-theirs\nb\n".write(toFile: path, atomically: true, encoding: .utf8)
        await session.save()
        let conflict = try #require(session.conflict)
        #expect(!conflict.canMerge)
        await session.takeTheirs()
        #expect(session.textController?.text == "a-theirs\nb\n")
        #expect(session.isDirty == false)
        session.close()
    }

    /// The session's FSEvents watcher runs alongside the explicit `handleExternalChange` calls here, so a reload it
    /// started for v2 may still be reading when the edit below lands; the session keeps the edit in that case.
    @Test func externalChangeReloadsWhenClean() async throws {
        let (directory, path) = try makeFile("v1\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        try await Task.sleep(for: .milliseconds(5))
        try "v2\n".write(toFile: path, atomically: true, encoding: .utf8)
        await session.handleExternalChange()
        #expect(session.textController?.text == "v2\n")
        #expect(session.banner == nil)
        session.textController?.replaceAll(with: "v2 edited\n")
        session.textController?.onTextChange()
        try await Task.sleep(for: .milliseconds(5))
        try "v3\n".write(toFile: path, atomically: true, encoding: .utf8)
        await session.handleExternalChange()
        #expect(session.banner == .externalChange)
        #expect(session.textController?.text == "v2 edited\n", "unsaved edits are kept")
        session.close()
    }

    @Test func largeFilesOpenReadOnly() async throws {
        let big = String(repeating: "x", count: Int(DocumentSession.readOnlyThreshold) + 1)
        let (directory, path) = try makeFile(big, name: "big.txt")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        #expect(session.isReadOnly)
        #expect(session.banner == .readOnlyLargeFile)
        #expect(session.textController?.isEditable == false)
        session.close()
    }
}
