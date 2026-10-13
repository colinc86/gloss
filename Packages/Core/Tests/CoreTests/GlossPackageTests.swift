import Foundation
import Testing
@testable import Core

/// A temporary folder with a review package in it, owned by `owner`, removed by `remove()`.
struct GlossFixture {
    static let content = Data("# Read me\n\nHello.\n".utf8)
    let folder: URL
    let owner = AuthorID.new()
    let participant = AuthorID.new()
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "gloss-tests-\(ULID.generate())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    var url: URL { folder.appending(path: "Review of README.gloss", directoryHint: .isDirectory) }

    func create() throws -> GlossPackageWriter {
        try GlossPackageWriter.create(
            at: url, owner: owner, ownerName: "Alex", title: "README.md", kind: .markdown,
            source: .file(name: "README.md", git: GlossGitLocation(origin: "github.com/o/r", path: "docs/README.md", commit: "abc1234")),
            content: Self.content, ext: "md", contentFacts: .object(["encoding": .string("utf-8")]), at: start)
    }

    func writer(_ author: AuthorID) throws -> GlossPackageWriter {
        try GlossPackageWriter(package: GlossPackage(url: url), author: author)
    }

    var anchor: Anchor {
        .text(TextAnchor(start: TextPosition(line: 1, col: 1), end: TextPosition(line: 1, col: 10), text: "# Read me",
                         before: "", after: "\nHello.", hash: Self.content.sha256Hex))
    }

    func note(by author: AuthorID, _ body: String = "Shorter title?", at offset: TimeInterval = 10) -> GlossNote {
        GlossNote(id: .new(), author: author, createdAt: start + offset, updatedAt: start + offset, iteration: 0,
                  anchor: anchor, body: body, color: .blue)
    }
}

struct GlossPackageTests {
    @Test func jsonValueRoundTripsEveryKind() throws {
        let value: JSONValue = .object([
            "null": .null, "yes": .bool(true), "no": .bool(false), "int": .int(42), "big": .int(9_007_199_254_740_993),
            "double": .double(1.5), "text": .string("a/b"), "list": .array([.int(1), .string("x"), .object([:])]),
        ])
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded["yes"]?.boolValue == true && decoded["int"]?.intValue == 42, "booleans and integers keep their kind")
    }

    @Test func createsTheV1LayoutAndReadsItBack() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let hash = GlossFixture.content.sha256Hex
        #expect(owner.isOwner)

        let note = try owner.writeNote(fixture.note(by: fixture.owner))
        let message = GlossMessage(note: note.id, author: fixture.owner, via: GlossVia(agent: "Claude Code"), kind: .reply, body: "Done.", createdAt: fixture.start + 20)
        try owner.writeMessage(message)
        try owner.writeEvent(.sent(note.id, by: fixture.owner, to: "Claude Code", review: true, at: fixture.start + 15))
        let attachment = try owner.addAttachment(Data([0x89, 0x50, 0x4E, 0x47]), ext: "png")

        let files = Set(GlossPackage(url: fixture.url).files())
        #expect(files.isSuperset(of: [
            "Info.json", "content/\(hash).md", "iterations/0.json", "authors/\(fixture.owner)/author.json",
            "authors/\(fixture.owner)/notes/\(note.id).json", "authors/\(fixture.owner)/messages/\(message.id).json", attachment,
        ]))
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.path + "/.Review of README.gloss"), "no staging folder left behind")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path)
        #expect(siblings == ["Review of README.gloss"])

        let snapshot = try GlossPackage(url: fixture.url).read()
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.info.format == 1 && snapshot.info.minReader == 1)
        #expect(snapshot.info.ownerAuthor == fixture.owner && snapshot.info.documentKind == .markdown)
        #expect(snapshot.info.current == GlossCurrent(hash: hash, iteration: 0, capturedAt: fixture.start))
        #expect(snapshot.hasCurrentContent)
        #expect(snapshot.iterations.map(\.number) == [0] && snapshot.iterations.first?.snapshot == hash)
        #expect(snapshot.author(fixture.owner)?.name == "Alex")
        #expect(snapshot.notes == [note], "the anchor and every field survive the round trip")
        #expect(snapshot.messages == [message])
        #expect(snapshot.events.first?.eventType == .sent)
        #expect(snapshot.attachments == [attachment])
        #expect(GlossPackage(url: fixture.url).contentURL(hash: hash)?.lastPathComponent == "\(hash).md")
    }

    @Test func notesStoreTheAnchorAsAnObject() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let note = try owner.writeNote(fixture.note(by: fixture.owner))
        let data = try Data(contentsOf: GlossPackage(url: fixture.url).fileURL(GlossLayout.note(note.id, by: fixture.owner)))
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(object["anchorType"]?.stringValue == "text")
        #expect(object["anchor"]?["text"]?.stringValue == "# Read me")
        #expect(object["state"] == nil, "state is folded from events, never stored")
    }

    @Test func everyAnchorKindRoundTrips() throws {
        let anchors: [Anchor] = [
            .wholeFile,
            .image(ImageAnchor(x: 1, y: 2, w: 3, h: 4, imageW: 100, imageH: 80)),
            .pdf(PDFAnchor(page: 2, bounds: nil, text: "Total", pageCount: 12)),
        ]
        for anchor in anchors {
            var note = GlossFixture.noteTemplate
            note.anchor = anchor
            let decoded = try GlossCoding.decode(GlossNote.self, from: GlossCoding.encode(note))
            #expect(decoded.anchor == anchor)
        }
    }

    @Test func rewritesKeepTopLevelFieldsFromANewerGloss() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        var owner = try fixture.create()
        let package = GlossPackage(url: fixture.url)
        let infoURL = package.fileURL(GlossFormat.infoFile)
        var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: infoURL))
        object["futureField"] = .object(["kept": .bool(true)])
        try JSONEncoder().encode(object).write(to: infoURL)

        owner = try fixture.writer(fixture.owner)
        var info = owner.info
        info.title = "README.md (renamed)"
        try owner.writeInfo(info)
        let rewritten = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: infoURL))
        #expect(rewritten["futureField"]?["kept"]?.boolValue == true)
        #expect(rewritten["title"]?.stringValue == "README.md (renamed)")
    }

    @Test func refusesAPackageThatNeedsANewerReader() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        _ = try fixture.create()
        let infoURL = GlossPackage(url: fixture.url).fileURL(GlossFormat.infoFile)
        var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: infoURL))
        object["minReader"] = .int(2)
        try JSONEncoder().encode(object).write(to: infoURL)
        #expect(throws: GlossPackageError.needsNewerReader(2)) { try GlossPackage(url: fixture.url).read() }
    }

    @Test func refusesASourceThatNamesTheOwnersDisk() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        #expect(throws: GlossPackageError.self) {
            try GlossPackageWriter.create(at: fixture.url, owner: fixture.owner, ownerName: "Alex", title: "README.md", kind: .markdown,
                                          source: .file(name: "/Users/someone/README.md", git: nil), content: GlossFixture.content, ext: "md")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(GlossSource.file(name: "README.md", git: GlossGitLocation(origin: "github.com/o/r", path: "/abs/README.md")).privacyProblem != nil)
        #expect(GlossSource.web(url: "file:///tmp/a.html", reachable: true).privacyProblem != nil)
        #expect(GlossSource.jira(site: "example.atlassian.net", key: "CP-7").privacyProblem == nil)
    }

    @Test func sourcesRoundTripAndUnknownTypesAreKept() throws {
        let sources: [GlossSource] = [
            .file(name: "README.md", git: nil),
            .web(url: "http://localhost:3000/", reachable: false),
            .github(repo: "o/r", pull: 7, path: "src/app.swift", head: "abc", base: "def"),
            .jira(site: "example.atlassian.net", key: "CP-7"),
            .confluence(site: "example.atlassian.net", pageID: "123", version: 4),
            .other(.object(["type": .string("figma"), "file": .string("x")])),
        ]
        for source in sources {
            #expect(try JSONValue(encoding: source).decode(GlossSource.self) == source)
        }
    }

    @Test func eachAuthorWritesOnlyTheirOwnFolder() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        var participant = try fixture.writer(fixture.participant)
        #expect(!participant.isOwner)
        try participant.writeAuthor(name: "Morgan", joinedAt: fixture.start)

        #expect(throws: GlossPackageError.notYourFolder(fixture.owner)) { try participant.writeNote(fixture.note(by: fixture.owner)) }
        #expect(throws: GlossPackageError.notOwner) { try participant.addSnapshot(Data("x".utf8), ext: "md") }
        #expect(throws: GlossPackageError.notOwner) { try participant.writeInfo(participant.info) }
        #expect(throws: GlossPackageError.notOwner) {
            try participant.writeIteration(GlossIteration(number: 1, startedAt: fixture.start, snapshot: "x"))
        }

        let ownerNote = try owner.writeNote(fixture.note(by: fixture.owner))
        let mine = try participant.writeNote(fixture.note(by: fixture.participant, "Typo here"))
        #expect(throws: GlossPackageError.notOwner) { try participant.writeEvent(.sent(mine.id, by: fixture.participant, at: fixture.start)) }
        #expect(throws: GlossPackageError.notOwner) {
            try participant.writeEvent(GlossEvent(note: mine.id, author: fixture.participant, type: .accepted, at: fixture.start))
        }
        #expect(throws: GlossPackageError.self) {
            try participant.writeEvent(GlossEvent(note: ownerNote.id, author: fixture.participant, type: .deleted, at: fixture.start))
        }
        // Allowed: resolving anyone's note, deleting your own, the owner deleting anyone's.
        try participant.writeEvent(.resolved(ownerNote.id, by: fixture.participant, at: fixture.start + 30))
        try participant.writeEvent(GlossEvent(note: mine.id, author: fixture.participant, type: .deleted, at: fixture.start + 31))
        try owner.writeEvent(GlossEvent(note: mine.id, author: fixture.owner, type: .restored, at: fixture.start + 32))
        _ = participant
    }

    @Test func writeOnceFilesNeverChange() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let note = try owner.writeNote(fixture.note(by: fixture.owner))
        let message = GlossMessage(note: note.id, author: fixture.owner, kind: .comment, body: "First", createdAt: fixture.start)
        try owner.writeMessage(message)
        try owner.writeMessage(message)
        var changed = message
        changed.body = "Second"
        #expect(throws: GlossPackageError.writeOnceConflict(GlossLayout.message(message.id, by: fixture.owner))) { try owner.writeMessage(changed) }
    }

    @Test func readerDropsRecordsInTheWrongFolder() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        _ = try fixture.create()
        let package = GlossPackage(url: fixture.url)
        // Someone writes a note claiming to be the owner's into their own folder.
        let forged = fixture.note(by: fixture.owner, "Forged")
        try GlossPackageWriter.write(GlossCoding.encode(forged), to: package, GlossLayout.note(forged.id, by: fixture.participant))
        try GlossPackageWriter.write(Data("not json".utf8), to: package, GlossLayout.message(.new(), by: fixture.participant))
        let snapshot = try package.read()
        #expect(snapshot.notes.isEmpty)
        #expect(snapshot.issues.count == 2)
    }

    @Test func publishingChangedContentStartsOneIteration() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        var owner = try fixture.create()
        #expect(try owner.publish(iteration: 0, content: GlossFixture.content, ext: "md", at: fixture.start + 60) == false,
                "the current iteration with the same bytes writes nothing")
        let changed = Data("# Read me\n\nHello, world.\n".utf8)
        #expect(throws: GlossPackageError.iterationNotAfterCurrent(0)) { try owner.publish(iteration: 0, content: changed, ext: "md", at: fixture.start + 60) }
        #expect(try owner.publish(iteration: 1, content: changed, ext: "md", gitCommit: "def5678", at: fixture.start + 60))
        #expect(try owner.publish(iteration: 1, content: changed, ext: "md", at: fixture.start + 70) == false, "never a second rollover")

        let snapshot = try GlossPackage(url: fixture.url).read()
        #expect(snapshot.info.current == GlossCurrent(hash: changed.sha256Hex, iteration: 1, capturedAt: fixture.start + 60))
        #expect(snapshot.iterations.map(\.number) == [0, 1])
        #expect(snapshot.iterations[0].endedAt == fixture.start + 60 && snapshot.iterations[1].endedAt == nil)
        #expect(snapshot.snapshots == [GlossFixture.content.sha256Hex, changed.sha256Hex], "every iteration's content stays viewable")
    }

    @Test func theSameBytesAtAHigherNumberMirrorTheOwnersIteration() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        var owner = try fixture.create()
        let filesBefore = Set(GlossPackage(url: fixture.url).files().filter { $0.hasPrefix(GlossFormat.contentFolder + "/") })
        #expect(try owner.publish(iteration: 3, content: GlossFixture.content, ext: "md", at: fixture.start + 60))
        #expect(try owner.publish(iteration: 3, content: GlossFixture.content, ext: "md", at: fixture.start + 70) == false)
        #expect(try owner.publish(iteration: 2, content: GlossFixture.content, ext: "md", at: fixture.start + 70) == false, "an older number is stale")

        let snapshot = try GlossPackage(url: fixture.url).read()
        #expect(snapshot.info.current == GlossCurrent(hash: GlossFixture.content.sha256Hex, iteration: 3, capturedAt: fixture.start),
                "the existing capture is reused, with its time")
        #expect(snapshot.iterations.map(\.number) == [0, 3])
        #expect(snapshot.iterations[0].endedAt == fixture.start + 60 && snapshot.iterations[1].snapshot == GlossFixture.content.sha256Hex)
        #expect(Set(GlossPackage(url: fixture.url).files().filter { $0.hasPrefix(GlossFormat.contentFolder + "/") }) == filesBefore, "no new capture")
    }

    @Test func infoWithAnIdentifierThatIsntCanonicalIsRefused() throws {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("id", { $0["id"] = "g_../../x" }),
            ("instance", { $0["instance"] = "i_../evil" }),
            ("ownerAuthor", { $0["ownerAuthor"] = "u_.." }),
            ("ownerAuthors", { $0["ownerAuthors"] = ["u_../../etc"] }),
            ("origin", { $0["origin"] = ["review": "g_x/..", "instance": "i_01J0000000000000000000000Z", "iteration": 0, "copiedAt": "2026-10-13T00:00:00.000Z"] }),
            ("current.hash", { info in var current = info["current"] as! [String: Any]; current["hash"] = "../x"; info["current"] = current }),
        ]
        for (field, change) in cases {
            let fixture = try GlossFixture()
            defer { fixture.remove() }
            _ = try fixture.create()
            let url = GlossPackage(url: fixture.url).fileURL(GlossFormat.infoFile)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            change(&json)
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            #expect(throws: GlossPackageError.self, "\(field)") { try GlossPackage(url: fixture.url).readInfo() }
        }
    }

    @Test func onlyAnOwnersNotesAndTurnsNameAnAgent() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let participant = try fixture.writer(fixture.participant)
        var claimed = fixture.note(by: fixture.participant)
        claimed.via = GlossVia(agent: "Claude Code")
        try participant.writeNote(claimed)
        try participant.writeMessage(GlossMessage(note: claimed.id, author: fixture.participant, via: GlossVia(agent: "Claude Code"), kind: .question, body: "Pick one", createdAt: fixture.start + 20))
        var real = fixture.note(by: fixture.owner)
        real.via = GlossVia(agent: "Codex")
        try owner.writeNote(real)

        let snapshot = try GlossPackage(url: fixture.url).read()
        #expect(snapshot.notes.first { $0.id == claimed.id }?.via == nil)
        #expect(snapshot.messages.allSatisfy { $0.via == nil })
        #expect(snapshot.notes.first { $0.id == real.id }?.via?.agent == "Codex")
        #expect(snapshot.folded().first { $0.id == claimed.id }?.waitingOnUser == false, "a participant's note isn't an agent's question")
    }

    @Test func aPlantedFifoOrLinkNeverStallsOrStealsANote() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let package = GlossPackage(url: fixture.url)
        let note = fixture.note(by: fixture.owner)
        // Someone replaces the owner's note file with a FIFO: reading it would block forever.
        let path = GlossLayout.note(note.id, by: fixture.owner)
        try FileManager.default.createDirectory(at: package.fileURL(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(mkfifo(package.fileURL(path).path, 0o600) == 0)
        #expect(package.readIfSafe(path) == nil)
        #expect(throws: GlossPackageError.unsafePath(path)) { try owner.publish([GlossNoteBundle(note: note)], name: "Alex", at: fixture.start) }

        // A link planted in a folder that sorts first doesn't claim someone else's note.
        let other = fixture.note(by: fixture.owner)
        try owner.writeNote(other)
        let planted = AuthorID(rawValue: "u_00000000000000000000000000")
        let plantedPath = GlossLayout.note(other.id, by: planted)
        try FileManager.default.createDirectory(at: package.fileURL(plantedPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: package.fileURL(plantedPath), withDestinationURL: package.fileURL(GlossLayout.note(other.id, by: fixture.owner)))
        #expect(package.author(ofNote: other.id) == fixture.owner)
    }

    @Test func linksInsideThePackageAreNeverFollowed() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        _ = try fixture.create()
        let package = GlossPackage(url: fixture.url)
        let outside = fixture.folder.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        // Another author's folder is a link to somewhere else: writing as that author must not go through it.
        let linked = fixture.participant
        try FileManager.default.createSymbolicLink(at: package.fileURL("authors/" + linked.rawValue), withDestinationURL: outside)
        let writer = try fixture.writer(linked)
        #expect(throws: GlossPackageError.self) { try writer.writeNote(fixture.note(by: linked)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "nothing was written outside")

        // A snapshot that is a link reads as missing.
        let secret = outside.appending(path: "secret.txt")
        try Data("secret".utf8).write(to: secret)
        let hash = String(repeating: "b", count: 64)
        try FileManager.default.createSymbolicLink(at: package.fileURL("content/\(hash).md"), withDestinationURL: secret)
        #expect(package.contentURL(hash: hash) == nil)
        #expect(package.contentURL(hash: "../x") == nil)

        // Info.json as a link is refused.
        let info = package.fileURL(GlossFormat.infoFile)
        try FileManager.default.moveItem(at: info, to: outside.appending(path: "Info.json"))
        try FileManager.default.createSymbolicLink(at: info, withDestinationURL: outside.appending(path: "Info.json"))
        #expect(throws: GlossPackageError.unsafePath(GlossFormat.infoFile)) { try package.readInfo() }
    }

    @Test func folderCapturesAreContentAddressedByTheirManifest() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        var owner = try fixture.create()
        let dom = Data("<html></html>".utf8)
        let hash = try owner.addSnapshotFolder(["dom.html": dom, "shot.png": Data([1, 2, 3])])
        let package = GlossPackage(url: fixture.url)
        #expect(package.contentURL(hash: hash)?.lastPathComponent == hash)
        #expect(Set(package.files().filter { $0.hasPrefix("content/\(hash)/") }) == ["content/\(hash)/dom.html", "content/\(hash)/shot.png", "content/\(hash)/manifest.json"])
        #expect(try package.read().snapshots.contains(hash), "a complete folder capture counts as arrived")

        // The same DOM with a new screenshot is a different capture, not a conflict.
        let recapture = try owner.addSnapshotFolder(["dom.html": dom, "shot.png": Data([4, 5, 6])])
        #expect(recapture != hash)
        #expect(try owner.addSnapshotFolder(["dom.html": dom, "shot.png": Data([1, 2, 3])]) == hash, "adding it again is a no-op")

        var info = owner.info
        info.current = GlossCurrent(hash: recapture, iteration: 1, capturedAt: fixture.start + 5)
        try owner.writeInfo(info)
        try FileManager.default.removeItem(at: package.fileURL("content/\(recapture)/shot.png"))
        #expect(try !package.read().hasCurrentContent, "a capture missing a member hasn't arrived")
    }

    @Test func folderCapturesCheckEveryNameBeforeWriting() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let before = GlossPackage(url: fixture.url).files()
        for files in [["dom.html": Data("a".utf8), "zz/.hidden": Data("b".utf8)], ["a": Data("a".utf8), "a/b": Data("b".utf8)],
                      ["../escape": Data("a".utf8)], ["manifest.json": Data("a".utf8)]] {
            #expect(throws: GlossPackageError.self) { try owner.addSnapshotFolder(files) }
        }
        #expect(GlossPackage(url: fixture.url).files() == before, "nothing half-written")
        let content = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path + "/content")
        #expect(content.count == 1, "no staging folder left behind")
    }

    @Test func nestedFieldsFromANewerGlossSurviveARewrite() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        _ = try fixture.create()
        let package = GlossPackage(url: fixture.url)
        let infoURL = package.fileURL(GlossFormat.infoFile)
        var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: infoURL))
        guard case .object(var source) = object["source"], case .object(var git) = source["git"], case .object(var current) = object["current"] else {
            Issue.record("unexpected Info.json shape"); return
        }
        git["subdir"] = .string("docs")
        source["git"] = .object(git)
        source["size"] = .int(18)
        current["future"] = .bool(true)
        object["source"] = .object(source)
        object["current"] = .object(current)
        try JSONEncoder().encode(object).write(to: infoURL)

        var owner = try fixture.writer(fixture.owner)
        var info = owner.info
        info.title = "Renamed"
        try owner.writeInfo(info)
        let rewritten = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: infoURL))
        #expect(rewritten["source"]?["git"]?["subdir"]?.stringValue == "docs")
        #expect(rewritten["source"]?["size"]?.intValue == 18)
        #expect(rewritten["current"]?["future"]?.boolValue == true)

        info.content = nil
        try owner.writeInfo(info)
        let cleared = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: infoURL))
        #expect(cleared["content"] == nil, "a known field this Gloss cleared stays cleared")
    }

    @Test func anAnchorKeepsANewerGlosssFieldsWhileUnchanged() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let note = try owner.writeNote(fixture.note(by: fixture.owner))
        let url = GlossPackage(url: fixture.url).fileURL(GlossLayout.note(note.id, by: fixture.owner))
        var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        guard case .object(var anchor) = object["anchor"] else { Issue.record("no anchor"); return }
        anchor["future"] = .string("kept")
        object["anchor"] = .object(anchor)
        try JSONEncoder().encode(object).write(to: url)

        var read = try #require(try GlossPackage(url: fixture.url).read().notes.first)
        read.body = "Edited"
        try owner.writeNote(read)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))["anchor"]?["future"]?.stringValue == "kept")
        read.anchor = .wholeFile
        try owner.writeNote(read)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))["anchorType"]?.stringValue == "file")
    }

    @Test func sourcesNeverCarryCredentialsOrUsers() {
        let unsafe: [GlossSource] = [
            .file(name: "README.md", git: GlossGitLocation(origin: "https://x-access-token:secret@github.com/o/r.git", path: "README.md")),
            .file(name: "README.md", git: GlossGitLocation(origin: "git@github.com:o/r", path: "README.md")),
            .file(name: "README.md", git: GlossGitLocation(origin: "github.com:o/r", path: "README.md")),
            .file(name: "README.md", git: GlossGitLocation(origin: "github.com/o/r", path: "../../elsewhere/README.md")),
            .web(url: "https://user:pass@example.com/", reachable: true),
            .github(repo: "o/r", pull: 7, path: "../x", head: nil, base: nil),
        ]
        for source in unsafe { #expect(source.privacyProblem != nil, "\(source)") }
        #expect(GlossSource.file(name: "README.md", git: GlossGitLocation(origin: "github.com/o/r", path: "docs/README.md")).privacyProblem == nil)
        #expect(GlossSource.web(url: "http://localhost:3000/pricing", reachable: false).privacyProblem == nil)
    }

    @Test func aNoteIdInTwoFoldersIsUsedFromNeither() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let real = try owner.writeNote(fixture.note(by: fixture.owner))
        var forged = real
        forged.author = fixture.participant
        let package = GlossPackage(url: fixture.url)
        try GlossPackageWriter.write(GlossCoding.encode(forged), to: package, GlossLayout.note(real.id, by: fixture.participant))
        let snapshot = try package.read()
        #expect(snapshot.notes.isEmpty && snapshot.issues.count == 2)
    }

    @Test func onlyCanonicalIdentifiersNameFiles() {
        let author = AuthorID.new()
        let note = NoteID.new()
        #expect(GlossPath(relativePath: "authors/\(author.rawValue.lowercased())/author.json") == .other)
        #expect(GlossPath(relativePath: "authors/\(author)/notes/\(note.rawValue.lowercased()).json") == .other)
        #expect(GlossPath(relativePath: "authors/\(author)/notes/\(note).json") == .note(author, note))
    }

    @Test func strangersCantRestoreOrMoveSomeoneElsesNote() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let note = try owner.writeNote(fixture.note(by: fixture.owner))
        let participant = try fixture.writer(fixture.participant)
        #expect(throws: GlossPackageError.self) {
            try participant.writeEvent(GlossEvent(note: note.id, author: fixture.participant, type: .restored, at: fixture.start))
        }
        #expect(throws: GlossPackageError.self) {
            try participant.writeEvent(GlossEvent.moved(note.id, by: fixture.participant, to: .wholeFile, removed: false, at: fixture.start))
        }
    }

    @Test func pathsClassify() {
        let author = AuthorID.new()
        let note = NoteID.new()
        let hash = String(repeating: "a", count: 64)
        #expect(GlossPath(relativePath: "Info.json") == .info)
        #expect(GlossPath(relativePath: "content/\(hash).md") == .content(hash: hash))
        #expect(GlossPath(relativePath: "content/\(hash)/dom.html") == .contentMember(hash: hash))
        #expect(GlossPath(relativePath: "iterations/3.json") == .iteration(3))
        #expect(GlossPath(relativePath: "iterations/03.json") == .other)
        #expect(GlossPath(relativePath: GlossLayout.note(note, by: author)) == .note(author, note))
        #expect(GlossPath(relativePath: "authors/not-an-id/notes/\(note).json") == .other)
        #expect(GlossPath(relativePath: "content/README.md") == .other)
    }
}

extension GlossFixture {
    static var noteTemplate: GlossNote {
        GlossNote(id: .new(), author: .new(), createdAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
                  iteration: 0, anchor: .wholeFile, body: "Note", color: .green)
    }
}
