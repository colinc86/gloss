import Core
import Foundation
import PDFKit
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

    @Test func unknownExtensionsOpenAsTextWhenTheBytesAreText() async throws {
        let (directory, path) = try makeFile("{\"a\":1}\n{\"a\":2}\n", name: "events.weird")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        #expect(session.kind == .text)
        let controller = try #require(session.textController, "a text file with an unlisted extension is editable")
        #expect(controller.text.hasPrefix("{\"a\":1}") && controller.isEditable)
        #expect(session.document?.kind == .text, "the sniffed kind is what the store records")
        session.close()

        let binary = "\(directory)/blob.weird"
        try Data((0..<512).map { UInt8($0 % 31 + 1) }).write(to: URL(fileURLWithPath: binary))
        let other = try makeSession(path: binary)
        await other.open()
        #expect(other.kind == .file && other.textController == nil, "binary bytes stay with QuickLook")
        if case .quickLook = other.state {} else { Issue.record("expected QuickLook for a binary file, got \(other.state)") }
        other.close()
    }

    @Test func parsesGoToLineInput() {
        #expect(DocumentSession.parseGoToLine("12")! == (12, nil))
        #expect(DocumentSession.parseGoToLine(" 12:4 ")! == (12, 4))
        #expect(DocumentSession.parseGoToLine("12,4")! == (12, 4))
        for bad in ["", "0", "-3", "abc", "12:", "12:0", "1:2:3"] {
            #expect(DocumentSession.parseGoToLine(bad) == nil, "\(bad) is refused")
        }
    }

    @Test func goToLineSelectsTheLineOrPlacesTheCaret() async throws {
        let (directory, path) = try makeFile("one\ntwo\nthree\n", name: "a.txt")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        session.goTo(line: 2, column: nil)
        #expect(controller.pendingScroll == controller.lineIndex.contentRange(ofLine: 2))
        session.goTo(line: 3, column: 3)
        #expect(controller.pendingScroll == NSRange(location: controller.lineIndex.contentRange(ofLine: 3).location + 2, length: 0))
        session.goTo(line: 2, column: 99)
        #expect(controller.pendingScroll == NSRange(location: controller.lineIndex.contentRange(ofLine: 2).location + 3, length: 0), "a column past the end lands at the line end")
        session.close()
    }

    @Test func goToLineNeverSplitsAnEmoji() async throws {
        let (directory, path) = try makeFile("a😀b\n", name: "e.txt")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        session.goTo(line: 1, column: 3)   // UTF-16 offset 2 is the second half of the emoji
        #expect(controller.pendingScroll == NSRange(location: 1, length: 0), "the caret snaps to the emoji's start")
        session.close()
    }

    @Test func goToLineInRenderedMarkdownLandsOnSomethingShown() async throws {
        let (directory, path) = try makeFile("# Title\n\nFirst paragraph.\n\nSecond paragraph.\n", name: "r.md")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        let markdown = try #require(session.markdown)
        markdown.mode = .rendered
        let before = markdown.pendingRenderedScrollVersion
        session.goTo(line: 2, column: nil)   // a blank line: renders to nothing
        #expect(markdown.pendingRenderedScrollVersion == before + 1, "the jump goes to the next line that renders")
        session.goTo(line: 3, column: 4)     // a caret inside a paragraph
        #expect(markdown.pendingRenderedScrollVersion == before + 2)
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

    @Test func mergingKeepsCRLFAndTheMissingFinalNewline() async throws {
        let (directory, path) = try makeFile("one\r\ntwo\r\nthree\r\nfour", name: "run.bat")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        controller.viewDidChangeText( "ONE\r\ntwo\r\nthree\r\nfour")
        try await Task.sleep(for: .milliseconds(5))
        try Data("one\r\ntwo\r\nthree\r\nFOUR".utf8).write(to: URL(fileURLWithPath: path))
        await session.save()
        #expect(session.conflict?.canMerge == true)
        await session.mergeAndSave()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("ONE\r\ntwo\r\nthree\r\nFOUR".utf8))
        session.close()
    }

    /// A version written while the conflict sheet was open is never overwritten unseen: the conflict is rebuilt.
    @Test func resolvingAConflictRechecksTheFile() async throws {
        let (directory, path) = try makeFile("a\nb\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        controller.viewDidChangeText( "a-mine\nb\n")
        try await Task.sleep(for: .milliseconds(5))
        try "a-theirs\nb\n".write(toFile: path, atomically: true, encoding: .utf8)
        await session.save()
        let first = try #require(session.conflict)
        try await Task.sleep(for: .milliseconds(5))
        try "a-theirs\nb\nc-third\n".write(toFile: path, atomically: true, encoding: .utf8)
        await session.keepMine()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "a-theirs\nb\nc-third\n", "not overwritten unseen")
        let rebuilt = try #require(session.conflict)
        #expect(rebuilt.theirsText == "a-theirs\nb\nc-third\n" && rebuilt.theirsFingerprint != first.theirsFingerprint)
        session.close()
    }

    /// A non-UTF-8 file is saved in its own encoding, and a character it can't hold refuses the save.
    @Test func savesInTheFilesOwnEncoding() async throws {
        let (directory, path) = try makeFile("", name: "legacy.txt")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try Data([0x93, 0x71, 0x94, 0x0A]).write(to: URL(fileURLWithPath: path))   // “q” in Windows-1252
        let session = try makeSession(path: path)
        await session.open()
        #expect(session.textEncoding == .windows1252)
        let controller = try #require(session.textController)
        controller.viewDidChangeText( controller.text + "ok\n")
        await session.save()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([0x93, 0x71, 0x94, 0x0A, 0x6F, 0x6B, 0x0A]))
        controller.viewDidChangeText( controller.text + "→\n")
        await session.save()
        #expect(session.lastError?.contains("Windows-1252") == true && session.lastError?.contains("Convert to UTF-8") == true)
        #expect(session.banner == .decodedAsLatin1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == 7, "nothing written")
        session.lastError = nil
        session.convertToUTF8()
        await session.save()
        #expect(session.lastError == nil)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "\u{201C}q\u{201D}\nok\n→\n")
        session.close()

        // A UTF-8 file with a byte-order mark keeps it.
        let bom = "\(directory)/script.ps1"
        try (Data([0xEF, 0xBB, 0xBF]) + Data("Write-Host 'é'\r\n".utf8)).write(to: URL(fileURLWithPath: bom))
        let script = try makeSession(path: bom)
        await script.open()
        let editor = try #require(script.textController)
        editor.viewDidChangeText(editor.text + "# done\r\n")
        await script.save()
        #expect(try Data(contentsOf: URL(fileURLWithPath: bom)) == Data([0xEF, 0xBB, 0xBF]) + Data("Write-Host 'é'\r\n# done\r\n".utf8))
        script.close()
    }

    /// A "CSV" thousands of columns wide opens as text, not as a grid built column by column on the main thread.
    @Test func aVeryWideCSVOpensAsText() async throws {
        let (directory, path) = try makeFile(String(repeating: ",", count: 50_000) + "\n", name: "wide.csv")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let session = try makeSession(path: path)
        await session.open()
        #expect(session.textController != nil)
        if case .csv = session.state { Issue.record("opened as a grid") }
        session.close()

        let (narrowDirectory, narrow) = try makeFile("a,b\n1,2\n", name: "ok.csv")
        defer { try? FileManager.default.removeItem(atPath: narrowDirectory) }
        let grid = try makeSession(path: narrow)
        await grid.open()
        guard case .csv = grid.state else { Issue.record("a normal CSV is a grid"); return }
        grid.close()
    }

    @Test func aPasswordProtectedPDFSaysSoInsteadOfOpeningBlank() async throws {
        let (directory, path) = try makeFile("", name: "secret.pdf")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let plain = PDFDocument()
        plain.insert(PDFPage(), at: 0)
        #expect(plain.write(to: URL(fileURLWithPath: path), withOptions: [.userPasswordOption: "open-sesame", .ownerPasswordOption: "owner"]))
        let session = try makeSession(path: path)
        await session.open()
        guard case .failed(let message) = session.state else { Issue.record("opened \(session.state)"); return }
        #expect(message.contains("password-protected"))
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

struct OpenFailureMessageTests {
    @Test func fileErrorsReadAsSentences() {
        #expect(DocumentSession.openFailure(FileSystemError.notFound("/x")).hasPrefix("The file isn't there."))
        #expect(DocumentSession.openFailure(FileSystemError.permissionDenied("/x")) == "You don't have permission to read this file.")
        #expect(DocumentSession.openFailure(FileSystemError.io("timed out")).hasSuffix("timed out"))
    }
}

/// A jump to a line waits for the document, however long its host takes: a fixed 2.5 s lost it on a slow host.
@MainActor
struct LineJumpTests {
    @Test func aJumpWaitsForASlowDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-jump-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/a.swift"
        try (1...40).map { "line \($0)" }.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent),
                                      noteStore: NoteStore(database: try AppDatabase.inMemory()))
        let jump = Task { await AppModel.jump(session, line: 30, endLine: nil, select: true) }
        // Longer than the old wait before the document arrives.
        try await Task.sleep(for: .seconds(3))
        await session.open()
        await jump.value
        let controller = try #require(session.textController)
        #expect(controller.pendingScroll == controller.lineIndex.contentRange(ofLine: 30))
        session.close()
    }

    /// Revealing a note waits the same way (its card clicked while a slow host is still sending the file).
    @Test func aRevealWaitsForASlowDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-reveal-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/a.swift"
        let text = (1...40).map { "line \($0)" }.joined(separator: "\n")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let store = NoteStore(database: try AppDatabase.inMemory())
        let session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: store)
        let waited = Task { await AppModel.untilLoaded(session) }
        try await Task.sleep(for: .seconds(3))
        #expect(session.document == nil, "not opened yet")
        await session.open()
        await waited.value
        #expect(session.document != nil && session.isLoaded)
        session.close()
    }
}


/// Opening many documents lets the oldest go, but never one holding work that lives only in it.
@MainActor
struct SessionTrimTests {
    @Test func aNoteBeingWrittenKeepsItsDocumentOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-trim-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<12 { try "file \(index)".write(toFile: "\(root)/f\(index).txt", atomically: true, encoding: .utf8) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        model.openDocument(hostID: .local, path: "\(root)/f0.txt")
        let first = try #require(model.activeSession)
        for _ in 0..<100 where !first.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        first.noteEditor = NoteEditorState(anchor: .wholeFile, body: "half a thought", color: .yellow, anchorRect: .zero)
        for index in 1..<12 { model.openDocument(hostID: .local, path: "\(root)/f\(index).txt") }
        #expect(model.session(hostID: .local, path: "\(root)/f0.txt") === first, "the document with a note being written stays open")
        #expect(model.session(hostID: .local, path: "\(root)/f1.txt") == nil, "an idle older one is let go")
        await model.shutDown()
    }
}

/// A file Gloss can't show says why for where it is, and offers a whole-file note without the shortcut.
struct UnsupportedFileTests {
    @Test func theMessageFitsWhereTheFileIs() {
        #expect(ViewerPane.unsupportedMessage(hostID: HostID(rawValue: "h_box"), isPastIteration: false).contains("on a remote host"))
        #expect(!ViewerPane.unsupportedMessage(hostID: .github, isPastIteration: false).contains("remote host"), "a pull request's file isn't on a host")
        #expect(ViewerPane.unsupportedMessage(hostID: .local, isPastIteration: true) == "Gloss can't show an earlier version of this kind of file.",
                "an earlier iteration on this Mac, which takes no new notes")
    }
}
