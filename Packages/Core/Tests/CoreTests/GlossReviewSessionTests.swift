import Foundation
import Testing
@testable import Core

/// The sync layer on a local folder: file coordination and presenters work the same there as in iCloud Drive, only
/// without uploads and conflict versions (those need two Macs).
struct GlossReviewSessionTests {
    let alex = GlossIdentity(author: .new(), name: "Alex")
    let morgan = GlossIdentity(author: .new(), name: "Morgan")
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    var seed: GlossReviewSeed {
        GlossReviewSeed(title: "README.md", kind: .markdown, source: .file(name: "README.md", git: GlossGitLocation(origin: "github.com/o/r", path: "README.md")),
                        content: .file(GlossFixture.content, ext: "md"), iteration: 0, capturedAt: start)
    }

    /// A sent, resolved and accepted local note with an agent reply, a sent follow-up and an unsent draft follow-up.
    func localNote() -> (Note, [NoteMessage], [(Core.Attachment, Data)]) {
        let note = Note(id: .new(), documentID: .new(), anchor: .wholeFile, body: "Shorter title?", state: .resolved, color: .blue,
                        createdAt: start, updatedAt: start + 30, resolveOutcome: .done, resolveMessage: "Shortened.", resolveAgent: "Claude Code",
                        reviewRequested: true, acceptedAt: start + 40)
        let reply = NoteMessage(id: .new(), noteID: note.id, author: .agent("Claude Code"), kind: .reply, body: "Done", createdAt: start + 20, sentAt: start + 20)
        let followUp = NoteMessage(id: .new(), noteID: note.id, author: .user, kind: .comment, body: "Thanks", createdAt: start + 25, sentAt: start + 26)
        let draft = NoteMessage(id: .new(), noteID: note.id, author: .user, kind: .comment, body: "Unsent draft", createdAt: start + 50, sentAt: nil)
        let moved = NoteMessage(id: .new(), noteID: note.id, author: .app, kind: .moved, body: "", createdAt: start + 5, sentAt: start + 5)
        let attachment = Core.Attachment(id: .new(), noteID: note.id, kind: .crop, localPath: "/tmp/crop.png", width: 10, height: 8)
        return (note, [reply, followUp, draft, moved], [(attachment, Data([0x89, 0x50]))])
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "gloss-session-\(ULID.generate())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The first change matching `predicate`, or nil after `timeout`.
    func next(_ stream: AsyncStream<GlossReviewChange>, timeout: Duration = .seconds(10),
              where predicate: @escaping @Sendable (GlossReviewChange) -> Bool) async -> GlossReviewChange? {
        await withTaskGroup(of: GlossReviewChange?.self) { group in
            group.addTask {
                for await change in stream where predicate(change) { return change }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test func createsAReviewWithOnlyWhatWasSent() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (note, messages, attachments) = localNote()
        let bundle = GlossNoteBundle(note: note, messages: messages, attachments: attachments, identity: alex, isOwner: true,
                                     sentAt: start + 10, reviewRequested: true, agent: "Claude Code")
        let session = try GlossReviewSession.create(in: root, seed: seed, notes: [bundle], identity: alex, pollInterval: nil)
        defer { session.close() }

        #expect(session.url.lastPathComponent == "Review of README.md.gloss")
        #expect(session.isOwner)
        let snapshot = try session.snapshot()
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.notes.map(\.id) == [note.id], "local note ids carry over")
        #expect(snapshot.messages.map(\.body) == ["Done", "Thanks"], "no draft follow-up, no Gloss-made turn")
        #expect(snapshot.messages.first?.via?.agent == "Claude Code")
        let state = try #require(snapshot.folded().first)
        #expect(state.status == .resolved && state.isAgentVisible && state.reviewRequested && state.acceptedAt == start + 40)
        #expect(state.resolution?.via?.agent == "Claude Code" && state.resolution?.message == "Shortened.")
        let ref = try #require(snapshot.notes.first?.attachments?.first)
        #expect(try session.readFile(ref.path) == Data([0x89, 0x50]) && ref.width == 10)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(siblings == ["Review of README.md.gloss"], "no staging folder left behind")
    }

    @Test func aSecondReviewOfTheSameTitleGetsANumber() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        let second = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        defer { first.close(); second.close() }
        #expect(second.url.lastPathComponent == "Review of README.md 2.gloss")
        #expect(first.info.instance != second.info.instance)
    }

    @Test func publishingTwiceWritesNothingNew() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        defer { session.close() }
        let (note, messages, attachments) = localNote()
        let make = { GlossNoteBundle(note: note, messages: messages, attachments: attachments, identity: alex, isOwner: true, sentAt: start + 10) }
        let first = try session.publish([make()])
        #expect(first.notesWritten == [note.id] && first.messagesWritten == 2 && first.eventsWritten == 3 && first.attachmentsWritten == 1)
        let tree = try GlossPackage(url: session.url).treeHash()
        let again = try session.publish([make()])
        #expect(again.notesUnchanged == [note.id] && again.messagesWritten == 0 && again.eventsWritten == 0 && again.attachmentsWritten == 0)
        #expect(try GlossPackage(url: session.url).treeHash() == tree, "a retry changes no file")

        var edited = note
        edited.body = "Shorter title, please"
        let edit = try session.publish([GlossNoteBundle(note: edited, messages: messages, attachments: attachments, identity: alex, isOwner: true, sentAt: start + 10)])
        #expect(edit.notesWritten == [note.id])
    }

    @Test func aParticipantsSendReachesTheOwnersSession() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        let participant = try GlossReviewSession(url: owner.url, identity: morgan, pollInterval: nil)
        defer { owner.close(); participant.close() }
        #expect(!participant.isOwner)

        let changes = owner.changes()
        let posted = GlossNote(id: .new(), author: morgan.author, createdAt: start, updatedAt: start, iteration: 0, anchor: .wholeFile, body: "Typo", color: .pink)
        try participant.publish([GlossNoteBundle(note: posted)])

        let change = await next(changes) { if case .updated(_, let summary) = $0 { !summary.isEmpty } else { false } }
        guard case .updated(let snapshot, let summary)? = change else { Issue.record("no update reached the owner"); return }
        #expect(summary.newNotes == [posted.id] && summary.newAuthors == [morgan.author])
        #expect(snapshot.author(morgan.author)?.name == "Morgan")
        #expect(snapshot.folded().first?.status == .posted, "with the owner until the owner sends it")
    }

    @Test func theOwnersOwnWritesNeverCountAsNew() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        defer { owner.close() }
        let changes = owner.changes()
        let note = GlossNote(id: .new(), author: alex.author, createdAt: start, updatedAt: start, iteration: 0, anchor: .wholeFile, body: "Mine", color: .yellow)
        try owner.publish([GlossNoteBundle(note: note)])
        let change = await next(changes) { if case .updated(let snapshot, _) = $0 { !snapshot.notes.isEmpty } else { false } }
        guard case .updated(_, let summary)? = change else { Issue.record("no update after our own write"); return }
        #expect(summary.isEmpty)
    }

    @Test func aNewIterationReachesParticipantsOnceItsContentIsThere() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        let participant = try GlossReviewSession(url: owner.url, identity: morgan, pollInterval: nil)
        defer { owner.close(); participant.close() }
        let changes = participant.changes()
        #expect(try owner.publishIteration(0, content: .file(GlossFixture.content, ext: "md")) == false, "same iteration, same bytes")
        #expect(throws: GlossPackageError.notOwner) { try participant.publishIteration(1, content: .file(Data("x".utf8), ext: "md")) }
        #expect(try owner.publishIteration(1, content: .file(Data("# Read me\n\nChanged.\n".utf8), ext: "md"), gitCommit: "def5678"))
        let change = await next(changes) { if case .updated(_, let summary) = $0 { summary.iterationChanged } else { false } }
        guard case .updated(let snapshot, _)? = change else { Issue.record("participant never saw the iteration"); return }
        #expect(snapshot.info.current.iteration == 1 && snapshot.hasCurrentContent)
    }

    @Test func aSameByteIterationStillReachesParticipants() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        let participant = try GlossReviewSession(url: owner.url, identity: morgan, pollInterval: nil)
        defer { owner.close(); participant.close() }
        let changes = participant.changes()
        #expect(try owner.publishIteration(1, content: .file(GlossFixture.content, ext: "md")))
        let change = await next(changes) { if case .updated(_, let summary) = $0 { summary.iterationChanged } else { false } }
        guard case .updated(let snapshot, _)? = change else { Issue.record("participant never saw the iteration"); return }
        #expect(snapshot.info.current.iteration == 1 && snapshot.info.current.hash == GlossFixture.content.sha256Hex)
    }

    @Test func theOwnersSecondMacAdoptsTheReviewOnlyWhenICloudSaysOwner() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        let alexOnMini = GlossIdentity(author: .new(), name: "Alex")
        let second = try GlossReviewSession(url: first.url, identity: alexOnMini, pollInterval: nil)
        let participant = try GlossReviewSession(url: first.url, identity: morgan, pollInterval: nil)
        defer { first.close(); second.close(); participant.close() }

        var shared = GlossSyncStatus(), unshared = GlossSyncStatus(), local = GlossSyncStatus(), sharedNoRole = GlossSyncStatus()
        shared.isInICloud = true; shared.isShared = true; shared.role = .owner
        unshared.isInICloud = true
        sharedNoRole.isInICloud = true; sharedNoRole.isShared = true
        var asParticipant = shared
        asParticipant.role = .participant
        #expect(!second.isOwner)
        #expect(throws: GlossPackageError.notOwner) { try participant.adoptOwnership(status: asParticipant) }
        #expect(throws: GlossPackageError.notOwner) { try participant.adoptOwnership(status: sharedNoRole) }
        #expect(throws: GlossPackageError.notOwner) { try second.adoptOwnership(status: local) }
        #expect(try second.adoptOwnership(status: shared))
        #expect(second.isOwner, "at once, not after the refresh")
        #expect(try second.adoptOwnership(status: unshared) == false)
        #expect(try first.snapshot().info.owners == [alex.author, alexOnMini.author])
        #expect(try first.snapshot().info.ownerAuthor == alex.author, "the creator is still the named owner")
        #expect(try first.snapshot().author(alexOnMini.author)?.name == "Alex")

        // Owner-only writes work from the second Mac and count in the fold.
        let note = GlossNote(id: .new(), author: morgan.author, createdAt: Date(), updatedAt: Date(), iteration: 0, anchor: .wholeFile, body: "Hi", color: .green)
        try participant.publish([GlossNoteBundle(note: note)])
        try second.record([.sent(note.id, by: alexOnMini.author, at: Date())])
        #expect(try second.publishIteration(1, content: .file(Data("Changed".utf8), ext: "md")))
        #expect(try first.snapshot().folded().first { $0.id == note.id }?.status == .sent)
        #expect(throws: GlossPackageError.notOwner) { try participant.record([.sent(note.id, by: morgan.author, at: Date())]) }
    }

    @Test func anUnsharedReviewInICloudDriveIsTheAccountsOwn() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        let second = try GlossReviewSession(url: first.url, identity: GlossIdentity(author: .new(), name: "Alex"), pollInterval: nil)
        defer { first.close(); second.close() }
        var unshared = GlossSyncStatus()
        unshared.isInICloud = true
        #expect(try second.adoptOwnership(status: unshared))
        #expect(second.isOwner)
    }

    @Test func aDetachedCopyHasNoOwnerToAdopt() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        let copyFolder = try owner.makeCopy()
        defer { owner.close(); try? FileManager.default.removeItem(at: copyFolder.deletingLastPathComponent()) }
        let copy = try GlossReviewSession(url: copyFolder, identity: morgan, pollInterval: nil)
        defer { copy.close() }
        #expect(throws: GlossPackageError.self) { try copy.adoptOwnership(status: { var s = GlossSyncStatus(); s.isInICloud = true; return s }()) }
        #expect(!copy.isOwner)
    }

    @Test func thePollCatchesWritesThePresenterCantHear() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: 0.5)
        defer { owner.close() }
        let changes = owner.changes()
        // An uncoordinated write, as a sync engine that doesn't tell presenters might make.
        let note = GlossNote(id: .new(), author: morgan.author, createdAt: start, updatedAt: start, iteration: 0, anchor: .wholeFile, body: "Quiet", color: .green)
        try GlossPackageWriter.write(GlossCoding.encode(note), to: GlossPackage(url: owner.url), GlossLayout.note(note.id, by: morgan.author))
        let change = await next(changes) { if case .updated(_, let summary) = $0 { summary.newNotes == [note.id] } else { false } }
        #expect(change != nil)
        #expect(owner.pollDelay == 0.5, "a change the presenter missed keeps the poll quick")
    }

    @Test func readFileRefusesLinksAndSpecialFiles() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        defer { session.close() }
        let secret = root.appending(path: "secret.png")
        try Data("secret".utf8).write(to: secret)
        let package = GlossPackage(url: session.url)
        let hash = String(repeating: "c", count: 64)
        let attachment = "authors/\(morgan.author.rawValue)/attachments/\(hash).png"
        try FileManager.default.createDirectory(at: package.fileURL(attachment).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: package.fileURL(attachment), withDestinationURL: secret)
        #expect(throws: GlossPackageError.unsafePath(attachment)) { try session.readFile(attachment) }

        // A linked author folder holding a real-looking attachment path.
        let linkedFolder = "authors/\(alex.author.rawValue)/attachments"
        try FileManager.default.createDirectory(at: package.fileURL("authors/\(alex.author.rawValue)"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: package.fileURL(linkedFolder), withDestinationURL: root)
        #expect(throws: GlossPackageError.self) { try session.readFile(linkedFolder + "/secret.png") }

        let content = try #require(package.files().first { $0.hasPrefix("content/") })
        #expect(try session.readFile(content) == GlossFixture.content, "real files still read")
    }

    @Test func thePollBacksOffWhileThePresenterDeliversOrNothingChanges() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: 0.2)
        let participant = try GlossReviewSession(url: owner.url, identity: morgan, pollInterval: nil)
        defer { owner.close(); participant.close() }
        try await Task.sleep(for: .seconds(1))
        #expect(owner.pollDelay > 0.2, "quiet: it doubles")

        let changes = owner.changes()
        let note = GlossNote(id: .new(), author: morgan.author, createdAt: start, updatedAt: start, iteration: 0, anchor: .wholeFile, body: "Hi", color: .green)
        try participant.publish([GlossNoteBundle(note: note)])
        _ = await next(changes) { if case .updated(_, let summary) = $0 { summary.newNotes == [note.id] } else { false } }
        // The next poll after a presenter callback settles at the slowest interval.
        for _ in 0..<40 where owner.pollDelay < GlossReviewSession.quietPollInterval { try await Task.sleep(for: .milliseconds(100)) }
        #expect(owner.pollDelay == GlossReviewSession.quietPollInterval)
    }

    @Test func deletionAndMovesAreReported() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        defer { owner.close() }
        let changes = owner.changes()

        let moved = root.appending(path: "Renamed.gloss", directoryHint: .isDirectory)
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(writingItemAt: owner.url, options: .forMoving, writingItemAt: moved, options: .forReplacing, error: &error) { from, to in
            try? FileManager.default.moveItem(at: from, to: to)
            coordinator.item(at: from, didMoveTo: to)
        }
        #expect(error == nil)
        let move = await next(changes) { if case .moved = $0 { true } else { false } }
        guard case .moved(let url)? = move else { Issue.record("no move reported"); return }
        #expect(url.lastPathComponent == "Renamed.gloss" && owner.url.lastPathComponent == "Renamed.gloss")

        NSFileCoordinator().coordinate(writingItemAt: moved, options: .forDeleting, error: &error) { url in
            try? FileManager.default.removeItem(at: url)
        }
        let deleted = await next(changes) { if case .deleted = $0 { true } else { false } }
        #expect(deleted != nil)
    }

    @Test func aCopyIsDetachedAndInATemporaryFolder() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        defer { owner.close() }
        let copy = try owner.makeCopy()
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let info = try GlossPackage(url: copy).readInfo()
        #expect(info.instance != owner.info.instance && info.origin?.instance == owner.info.instance)
        #expect(copy.lastPathComponent == owner.url.lastPathComponent)
        #expect(!copy.path.hasPrefix(root.path))
    }

    @Test func duplicatesAreFoundAndAbsorbed() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        defer { owner.close() }
        let duplicate = root.appending(path: "Review of README.md 2.gloss", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: owner.url, to: duplicate)
        let stray = GlossNote(id: .new(), author: morgan.author, createdAt: start, updatedAt: start, iteration: 0, anchor: .wholeFile, body: "Offline", color: .green)
        try GlossPackageWriter.write(GlossCoding.encode(stray), to: GlossPackage(url: duplicate), GlossLayout.note(stray.id, by: morgan.author))
        _ = try GlossPackage(url: owner.url).makeCopy(to: root.appending(path: "A copy.gloss", directoryHint: .isDirectory))

        #expect(owner.duplicates().map(\.lastPathComponent) == ["Review of README.md 2.gloss"], "a detached copy is not a duplicate")
        _ = try owner.absorbDuplicate(duplicate) { try FileManager.default.removeItem(at: $0) }
        #expect(try owner.snapshot().notes.map(\.id) == [stray.id])
        #expect(!FileManager.default.fileExists(atPath: duplicate.path))
        #expect(try owner.resolveConflictsNow() == nil, "a local folder has no conflict versions")
    }

    @Test func closingEndsTheStreams() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        let changes = owner.changes()
        owner.close()
        var count = 0
        for await _ in changes { count += 1 }
        #expect(count == 1, "the first snapshot, then the end")
        var after = 0
        for await _ in owner.changes() { after += 1 }
        #expect(after == 0)
    }

    @Test func renamingKeepsTheAuthorRecord() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        defer { owner.close() }
        try owner.setName("Alex B.")
        let author = try #require(try owner.snapshot().author(alex.author))
        #expect(author.name == "Alex B." && author.joinedAt == start)
    }

    @Test func derivedEventIdsAreStableAndTimeOrdered() {
        let note = NoteID.new()
        let a = EventID.derived(note: note, type: .sent, author: alex.author, at: start)
        #expect(a == EventID.derived(note: note, type: .sent, author: alex.author, at: start))
        #expect(a != EventID.derived(note: note, type: .resolved, author: alex.author, at: start))
        #expect(a.rawValue < EventID.derived(note: note, type: .sent, author: alex.author, at: start + 1).rawValue)
        #expect(a.createdAt == start)
        #expect(GlossPath(relativePath: GlossLayout.event(a, by: alex.author)) == .event(alex.author, a))
    }

    @Test func aParticipantsBundleCarriesNoEventsOrAgentTurns() {
        let (note, messages, attachments) = localNote()
        let bundle = GlossNoteBundle(note: note, messages: messages, attachments: attachments, identity: morgan, isOwner: false, sentAt: start + 10)
        #expect(bundle.events.isEmpty)
        #expect(bundle.messages.map(\.body) == ["Thanks"])
        #expect(bundle.note.author == morgan.author && bundle.note.via == nil)
    }

    @Test func millisecondDatesSurviveSoARepublishWritesNothing() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        defer { session.close() }
        for index in 0..<200 {
            // Rounded to the millisecond the way NoteStore stores dates.
            let date = Date(timeIntervalSince1970: ((1_790_000_000 + Double(index) * 7.123457) * 1000).rounded() / 1000)
            #expect(GlossCoding.parse(GlossCoding.format(date)) == date)
            let note = Note(id: .new(), documentID: .new(), anchor: .wholeFile, body: "n", state: .sent, color: .yellow, createdAt: date, updatedAt: date)
            let bundle = GlossNoteBundle(note: note, messages: [], attachments: [], identity: alex, isOwner: true, sentAt: date)
            _ = try session.publish([bundle])
            #expect(try session.publish([bundle]).notesUnchanged == [note.id])
        }
    }

    @Test func anAcceptanceNeverReadsAsBeforeItsResolve() throws {
        let (base, messages, _) = localNote()
        for offset in 0..<50 {
            var note = base
            note.id = .new()
            let accepted = start + 60 + Double(offset) * 0.001
            note.updatedAt = accepted
            note.acceptedAt = accepted
            let bundle = GlossNoteBundle(note: note, messages: messages.map { var m = $0; m.noteID = note.id; return m }, attachments: [],
                                         identity: alex, isOwner: true, sentAt: start + 10, resolvedAt: accepted)
            let info = GlossInfo(id: .new(), instance: .new(), createdAt: start, ownerAuthor: alex.author, kind: .markdown, title: "README.md",
                                 source: .file(name: "README.md", git: nil), current: GlossCurrent(hash: "h", iteration: 0, capturedAt: start))
            let state = GlossFold.fold(bundle.note, messages: bundle.messages, events: bundle.events, info: info)
            #expect(state.acceptedAt != nil && state.status == .resolved)
        }
        // Later local edits move updatedAt but not the resolve.
        var edited = base
        edited.updatedAt = start + 500
        let before = GlossNoteBundle(note: base, messages: messages, attachments: [], identity: alex, isOwner: true, sentAt: start + 10)
        let after = GlossNoteBundle(note: edited, messages: messages, attachments: [], identity: alex, isOwner: true, sentAt: start + 10)
        #expect(before.events.map(\.id) == after.events.map(\.id))
    }

    @Test func otherContributorsRowsAreNeverPublishedAsMine() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        let participant = try GlossReviewSession(url: owner.url, identity: morgan, pollInterval: nil)
        defer { owner.close(); participant.close() }
        let theirs = GlossNote(id: .new(), author: morgan.author, createdAt: start, updatedAt: start, iteration: 0, anchor: .wholeFile, body: "Morgan's", color: .pink)
        try participant.publish([GlossNoteBundle(note: theirs)])

        // The owner's local copy of Morgan's note and of a turn Morgan wrote, as an import would store them.
        var imported = Note(id: theirs.id, documentID: .new(), anchor: .wholeFile, body: "Morgan's", state: .sent, color: .pink, createdAt: start, updatedAt: start)
        imported.contributorID = morgan.author.rawValue
        var turn = NoteMessage(id: .new(), noteID: theirs.id, author: .user, kind: .comment, body: "From Morgan", createdAt: start, sentAt: start)
        turn.contributorID = morgan.author.rawValue
        let bundle = GlossNoteBundle(note: imported, messages: [turn], attachments: [], identity: alex, isOwner: true, sentAt: start + 1)
        #expect(bundle.messages.isEmpty)
        let report = try owner.publish([bundle])
        #expect(report.notesRefused == [theirs.id] && report.notesWritten.isEmpty)
        #expect(try owner.snapshot().notes.map(\.author) == [morgan.author], "Morgan's note is still readable")

        let namespaced = Note(id: NoteID(rawValue: "\(owner.info.instance):\(theirs.id)"), documentID: .new(), anchor: .wholeFile, body: "x",
                              state: .sent, color: .pink, createdAt: start, updatedAt: start)
        #expect(try owner.publish([GlossNoteBundle(note: namespaced, messages: [], attachments: [], identity: alex, isOwner: true, sentAt: nil)]).notesRefused.count == 1)
    }

    @Test func attachmentPathsStayInsideTheirAuthorsFolder() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try GlossReviewSession.create(in: root, seed: seed, notes: [], identity: alex, pollInterval: nil)
        defer { owner.close() }
        let secret = root.appending(path: "secret.txt")
        try Data("secret".utf8).write(to: secret)
        #expect(throws: GlossPackageError.self) { try owner.readFile("../secret.txt") }
        #expect(throws: GlossPackageError.self) { try owner.readFile("authors/\(morgan.author)/attachments/../../../../secret.txt") }
        #expect(throws: GlossPackageError.self) { try owner.readFile("Info.json") }

        let ref = GlossAttachmentRef(path: "../secret.txt", kind: .crop, width: 1, height: 1)
        let note = GlossNote(id: .new(), author: morgan.author, createdAt: start, updatedAt: start, iteration: 0, anchor: .wholeFile, body: "x", color: .pink, attachments: [ref])
        try GlossPackageWriter.write(GlossCoding.encode(note), to: GlossPackage(url: owner.url), GlossLayout.note(note.id, by: morgan.author))
        let snapshot = try owner.snapshot()
        #expect(snapshot.notes.first?.attachments == [], "the reader drops refs outside the author's folder")
        #expect(snapshot.issues.count == 1)
    }

    @Test func duplicatesAreOnlySiblingsWithTheSameName() {
        #expect(GlossReviewSession.baseName("Review of README.md 2") == "Review of README.md")
        #expect(GlossReviewSession.baseName("Review of README.md") == "Review of README.md")
        #expect(GlossReviewSession.baseName("Review of v 1") == "Review of v 1")
    }

    @Test func locationsNameAndFindReviews() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GlossLocations.defaultFileName(for: "a/b:c.md") == "Review of a-b-c.md")
        #expect(GlossLocations.defaultFileName(for: "  ") == "Review of Untitled")
        try FileManager.default.createDirectory(at: root.appending(path: "One.gloss"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: ".Two.gloss.icloud"))
        try Data().write(to: root.appending(path: "notes.txt"))
        #expect(GlossLocations.reviews(in: [root]).map(\.lastPathComponent) == ["One.gloss", "Two.gloss"], "evicted packages are listed by name")
        #expect(GlossLocations.availableURL(in: root, name: "Two").lastPathComponent == "Two 2.gloss")
    }
}
