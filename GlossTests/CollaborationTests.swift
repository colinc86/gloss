import Core
import Foundation
import Synchronization
import Testing
import Viewers
@testable import Gloss

@MainActor
struct CollaborationTests {
    func model() async throws -> CollaborationModel {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let settings = SettingsStore(noteStore: store)
        await settings.load()
        return CollaborationModel(store: store,settings: settings)
    }
    func package(owner: GlossIdentity, notes: [GlossNoteBundle] = []) async throws -> (URL,URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlossCollaborationTests-" + UUID().uuidString)
        let seed = GlossReviewSeed(title: "README.md",kind: .markdown,source: .file(name: "README.md",git: nil),content: .file(Data("# Captured\n".utf8),ext: "md"),iteration: 0)
        let url = try await Task.detached {
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            let session = try GlossReviewSession.create(in: folder,seed: seed,notes: notes,identity: owner)
            defer { session.close() }
            return session.url
        }.value
        return (folder,url)
    }
    @Test func openingAReviewUsesCapturedReadOnlyContentAndUnknownPermissionIsNotWriteAccess() async throws {
        let model = try await model()
        let (folder,url) = try await package(owner: GlossIdentity(author: .new(),name: "Alex"))
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        #expect(review.isParticipant && !review.canWrite)
        let session = DocumentSession(hostID: .gloss,path: review.capturePath,fileSystem: model.fileSystem,noteStore: model.store)
        session.indexedDocumentID = review.documentID
        await session.open()
        #expect(session.isReadOnly && session.baseText == "# Captured\n")
        #expect(session.document?.hostID == .gloss)
        session.close()
        await model.stop()
    }
    @Test func participantSendPublishesExactOwnNotesWithoutAgentDelivery() async throws {
        let model = try await model()
        model.settings.yourName = "Morgan"
        var writeStatus = GlossSyncStatus(); writeStatus.isShared = true; writeStatus.canWrite = true; writeStatus.role = .participant
        let platformStatus = writeStatus
        model.statusReader = { _ in platformStatus }
        let (folder,url) = try await package(owner: GlossIdentity(author: .new(),name: "Alex"))
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        review.status.isShared = true; review.status.canWrite = true; review.status.role = .participant
        let note = try await model.store.createNote(documentID: review.documentID,anchor: .wholeFile,body: "My draft",color: .green)
        let packageSession = review.session
        #expect(try await Task.detached { try packageSession.snapshot().notes.isEmpty }.value)
        await model.publish([note.id],in: review)
        let snapshot = try await Task.detached { try packageSession.snapshot() }.value
        #expect(snapshot.notes.count == 1 && snapshot.notes.first?.body == "My draft")
        #expect(snapshot.folded().first?.status == .posted)
        #expect(try await model.store.sharedNoteIDs().isEmpty)
        #expect(try await model.store.sends(for: note.id).isEmpty)
        #expect(try await model.store.note(note.id)?.publishedAt != nil)
        await model.stop()
    }
    @Test func foreignCommentsAndModerationRespectParticipantPermissions() async throws {
        let model = try await model(), owner = GlossIdentity(author: .new(),name: "Alex")
        let remote = GlossNote(id: .new(),author: owner.author,createdAt: Date(),updatedAt: Date(),iteration: 0,anchor: .wholeFile,body: "Owner note",color: .yellow)
        let (folder,url) = try await package(owner: owner,notes: [GlossNoteBundle(note: remote)])
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        review.status.isShared = true; review.status.canWrite = true; review.status.role = .participant
        let foreign = try #require(try await model.store.notes(for: review.documentID).first)
        #expect(!model.canEdit(foreign) && !model.canDelete(foreign))
        #expect(await model.change(foreign,type: .resolved))
        #expect(!(await model.change(foreign,type: .accepted)))
        #expect(!(await model.change(foreign,type: .deleted)))
        let packageSession = review.session
        let snapshot = try await Task.detached { try packageSession.snapshot() }.value
        #expect(snapshot.folded().first?.status == .resolved && snapshot.folded().first?.acceptedAt == nil)
        await model.stop()
    }
    @Test func copiesHaveNoOwnerSinkAndStableIdentitySurvivesSettingsReload() async throws {
        let model = try await model()
        let (folder,url) = try await package(owner: model.settings.collaborationIdentity)
        defer { try? FileManager.default.removeItem(at: folder) }
        let identity = model.settings.collaborationIdentity
        let copy = try await Task.detached {
            let session = try GlossReviewSession(url: url,identity: identity)
            defer { session.close() }
            return try session.makeCopy()
        }.value
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        await model.open(copy)
        let review = try #require(model.reviews.first)
        #expect(review.isCopy && !review.isOwner && !review.canWrite)
        let fresh = SettingsStore(noteStore: model.store)
        await fresh.load()
        #expect(fresh.authorID == model.settings.authorID)
        await model.stop()
    }
    @Test func reopeningIndexedReviewDoesNotDuplicateNotesOrClearUnread() async throws {
        let model = try await model(), owner = GlossIdentity(author: .new(),name: "Alex")
        let remote = GlossNote(id: .new(),author: owner.author,createdAt: Date(),updatedAt: Date(),iteration: 0,anchor: .wholeFile,body: "Published",color: .yellow)
        let (folder,url) = try await package(owner: owner,notes: [GlossNoteBundle(note: remote)])
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        let ids = try await model.store.notes(for: review.documentID).map(\.id)
        await model.open(url)
        #expect(model.reviews.count == 1)
        #expect(try await model.store.notes(for: review.documentID).map(\.id) == ids)
        #expect(!review.unread.isEmpty)
        let before = review.unread
        await model.markAllSeen(review)
        #expect(review.unread.isEmpty && !before.isEmpty)
        let saved = try await model.store.seenReviewRecords(review.id)
        #expect(before.isSubset(of: saved))
        await model.stop()
    }
}

extension CollaborationTests {
    @Test func viewOnlyCaptureUpdatesAndOlderCaptureIsRetained() async throws {
        let model = try await model()
        var status = GlossSyncStatus(); status.isShared = true; status.canWrite = false; status.role = .participant
        let fixtureStatus = status; model.statusReader = { _ in fixtureStatus }
        let (folder,url) = try await package(owner: GlossIdentity(author: .new(),name: "Alex"))
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        let session = DocumentSession(hostID: .gloss,path: review.capturePath,fileSystem: model.fileSystem,noteStore: model.store)
        session.indexedDocumentID = review.documentID; session.mayAddNotes = { false }
        await session.open()
        try await Task.sleep(for: .milliseconds(30))
        let identity = GlossIdentity(author: review.snapshot.info.ownerAuthor,name: "Alex")
        try await Task.detached {
            let writer = try GlossReviewSession(url: url,identity: identity)
            defer { writer.close() }
            _ = try writer.publishIteration(1,content: .file(Data("# Updated\n".utf8),ext: "md"),at: Date())
        }.value
        await model.retry(review)
        for _ in 0..<100 where session.baseText != "# Updated\n" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.baseText == "# Updated\n" && session.isReadOnly)
        let retained = try #require(try await model.store.iterations(for: review.documentID).first { $0.number == 0 }?.snapshotHash)
        #expect(try await model.store.snapshot(hash: retained) == Data("# Captured\n".utf8))
        session.close(); await model.stop()
    }
    @Test func sendFreezesAttachmentsBeforeChangesDuringDelivery() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlossFrozenAttachment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("image.png"), crop = folder.appendingPathComponent("crop.png")
        try Data("image".utf8).write(to: image); try Data("sent crop".utf8).write(to: crop)
        let document = try await store.upsertDocument(hostID: .local,path: image.path,kind: .image,fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id,anchor: .image(ImageAnchor(x: 1,y: 2,w: 3,h: 4,imageW: 10,imageH: 10)),body: "Review crop",color: .yellow)
        _ = try await store.addAttachment(noteID: note.id,kind: .crop,localPath: crop.path,width: 3,height: 4)
        let info = GlossInfo(id: .new(),instance: .new(),createdAt: Date(),ownerAuthor: .new(),kind: .image,title: "image.png",source: .file(name: "image.png",git: nil),current: GlossCurrent(hash: Data("image".utf8).sha256Hex,iteration: 0,capturedAt: Date()))
        try await store.indexReview(info,url: folder.appendingPathComponent("Review.gloss"),documentID: document.id,isOwner: true)
        let transport = FakeTransport()
        transport.whileDelivering = {
            try? Data("private replacement".utf8).write(to: crop)
            _ = try? await store.addAttachment(noteID: note.id,kind: .crop,localPath: crop.path,width: 8,height: 9)
        }
        let sender = SendCoordinator(noteStore: store,transports: [transport],stagers: [.local: LocalAttachmentStager(cacheRoot: folder.appendingPathComponent("cache"))])
        await sender.send(noteIDs: [note.id],to: FakeTransport.target)
        #expect(sender.lastResult?.failure == nil)
        let immutable = try await store.agentResourceAttachments(note.id)
        #expect(immutable.count == 1 && immutable.first?.data == Data("sent crop".utf8))
        #expect(immutable.first?.attachment.width == 3)
        let visible = try await store.agentResourceAttachments(note.id)
        #expect(visible.first?.data == Data("sent crop".utf8))
        let retained = try #require(visible.first?.attachment.localPath)
        #expect(retained != crop.path)
        let packet = try await sender.packet(noteIDs: [note.id],wholeThread: true)
        #expect(packet.text.contains(retained) && !packet.text.contains(crop.path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: retained)) == Data("sent crop".utf8))
    }
}

extension CollaborationTests {
    @Test func markdownCaptureRejectsNonImagesAndReferencesOutsideItsResourceFolder() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlossCaptureValidation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("README.md")
        try Data("![Picture](secret.png)".utf8).write(to: path)
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("secret.png"))
        let session = DocumentSession(hostID: .local,path: path.path,fileSystem: LocalFileSystem(),noteStore: store)
        await session.open()
        defer { session.close() }
        await #expect(throws: GlossPackageError.self) { _ = try await ReviewCapture.saved(session,provider: LocalFileSystem(),browser: WebBrowserController()) }
        try Data("![Picture](../outside.png)".utf8).write(to: path)
        await #expect(throws: GlossPackageError.self) { _ = try await ReviewCapture.saved(session,provider: LocalFileSystem(),browser: WebBrowserController()) }
    }
    @Test func viewportRefusesAnUnattachedSourceBeforeAccessingTheBrowserPage() async throws {
        let expected = HTMLViewerController(source: TextEditorController(text: "<p>Fixture</p>"),documentPath: "/tmp/fixture.html",loadResource: { _ in Data() })
        await #expect(throws: GlossPackageError.self) { _ = try await ReviewCapture.viewport(WebBrowserController(),expected: expected) }
    }
}

extension CollaborationTests {
    @Test func aNewReviewStartsWithOnlyTheCurrentCaptureAndCurrentNotes() async throws {
        let model = try await model()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlossShareStart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("README.md")
        let old = Data("# Before sharing\n![Old picture](missing.png)\n".utf8)
        let current = Data("# At share time\n".utf8)
        try current.write(to: path)
        let document = try await model.store.upsertDocument(hostID: .local,path: path.path,kind: .markdown,fingerprint: Fingerprint())
        let source = DocumentSession(hostID: .local,path: path.path,fileSystem: LocalFileSystem(),noteStore: model.store)
        await source.open()
        defer { source.close() }
        let prior = try await model.store.createNote(documentID: document.id,anchor: .wholeFile,body: "Old round",color: .yellow)
        _ = try await model.store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [prior.id],outcome: .delivered,carriedNotes: [prior])
        try await model.store.resolve(prior.id)
        _ = try await model.store.startIteration(documentID: document.id,openNotes: .leave,snapshot: old)
        let note = try await model.store.createNote(documentID: document.id,anchor: .wholeFile,body: "Current round",color: .green)
        _ = try await model.store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [note.id],outcome: .delivered,carriedNotes: [note])
        model.sourceFileSystem = { _ in LocalFileSystem() }
        await model.prepareShare(source,copy: true,browser: WebBrowserController(),portableSource: .file(name: "README.md",git: nil))
        let url = try #require(model.shareURL, "\(model.error ?? "No copy prepared")")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let identity = model.settings.collaborationIdentity
        let exported = try await Task.detached {
            let session = try GlossReviewSession(url: url,identity: identity)
            defer { session.close() }
            return try session.snapshot()
        }.value
        #expect(exported.info.current.iteration == 1)
        #expect(exported.iterations.map(\.number) == [1])
        #expect(exported.snapshots == [current.sha256Hex])
        #expect(exported.notes.map(\.id) == [note.id])
        #expect(!exported.notes.contains { $0.id == prior.id })
        await model.stop()
    }
}

extension CollaborationTests {
    @Test func submittingTheSameNameDoesNotRewriteTheAuthorProfile() async throws {
        let model = try await model()
        let (folder,url) = try await package(owner: model.settings.collaborationIdentity)
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        model.settings.yourName = "Morgan"
        await model.updateName()
        let session = review.session, author = model.settings.authorID
        let first = try #require(try await Task.detached { try session.snapshot().author(author) }.value)
        await model.updateName()
        let again = try #require(try await Task.detached { try session.snapshot().author(author) }.value)
        #expect(first.name == "Morgan" && first.rev == again.rev)
        await model.stop()
    }
}

extension CollaborationTests {
    @Test func anAdoptedOwnerUsesTheOwnerSetAndParticipantRoleStillWins() async throws {
        let model = try await model()
        let (folder,url) = try await package(owner: GlossIdentity(author: .new(),name: "Alex"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let identity = model.settings.collaborationIdentity
        let session = try await Task.detached { try GlossReviewSession(url: url,identity: identity) }.value
        defer { Task.detached { session.close() } }
        var snapshot = try await Task.detached { try session.snapshot() }.value
        var status = GlossSyncStatus(); status.isShared = true; status.role = .owner; status.canWrite = true
        #expect(CollaborationModel.shouldAdoptOwnership(snapshot,author: identity.author,status: status))
        snapshot.info.ownerAuthors = [snapshot.info.ownerAuthor,identity.author]
        let context = ReviewContext(session: session,documentID: .new(),capturePath: "/fixture/README.md",snapshot: snapshot,status: status)
        #expect(context.isOwner && context.canWrite)
        #expect(!CollaborationModel.shouldAdoptOwnership(snapshot,author: identity.author,status: status))
        context.status.role = .participant
        #expect(!context.isOwner)
        snapshot.info.ownerAuthors = nil
        status.role = .participant
        #expect(!CollaborationModel.shouldAdoptOwnership(snapshot,author: identity.author,status: status))
        status.role = nil
        #expect(!CollaborationModel.shouldAdoptOwnership(snapshot,author: identity.author,status: status))
        status.isShared = false; status.isInICloud = true
        #expect(CollaborationModel.shouldAdoptOwnership(snapshot,author: identity.author,status: status))
        status.isInICloud = false
        #expect(!CollaborationModel.shouldAdoptOwnership(snapshot,author: identity.author,status: status))
        snapshot.info.origin = GlossOrigin(review: snapshot.info.id,instance: .new(),iteration: 0,copiedAt: Date())
        status.isShared = true; status.role = .owner
        #expect(!CollaborationModel.shouldAdoptOwnership(snapshot,author: identity.author,status: status))
        status.isShared = false; status.isInICloud = true; status.role = nil
        #expect(!CollaborationModel.shouldAdoptOwnership(snapshot,author: identity.author,status: status))
        await model.stop()
    }
    @Test func theSharedReviewMirrorsASameByteLocalIterationWithoutAnotherRollover() async throws {
        let model = try await model()
        let bytes = Data("# Captured\n".utf8)
        let (folder,url) = try await package(owner: model.settings.collaborationIdentity)
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        let before = review.snapshot.info.current
        let document = try await model.store.upsertDocument(hostID: .local,path: folder.appendingPathComponent("README.md").path,kind: .markdown,fingerprint: Fingerprint(hash: bytes.sha256Hex))
        try await model.store.linkReviewOriginal(review.id,to: document.id,baseline: bytes)
        await model.relink(review,to: document.id)
        _ = try await model.store.startIteration(documentID: document.id,openNotes: .leave,snapshot: bytes)
        model.sourceFileSystem = { _ in LocalFileSystem() }
        model.captureSource = { _ in (.file(bytes,ext: "md"),nil) }
        await model.synchronizeOwnerChanges()
        #expect(review.snapshot.info.current.iteration == 1)
        #expect(review.snapshot.info.current.hash == before.hash)
        #expect(review.snapshot.info.current.capturedAt == before.capturedAt)
        #expect(review.snapshot.snapshots.count == 1)
        #expect(try await model.store.document(document.id)?.currentIteration == 1)
        await model.synchronizeOwnerChanges()
        #expect(review.snapshot.info.current.iteration == 1)
        #expect(try await model.store.iterations(for: document.id).map(\.number) == [0,1])
        await model.stop()
    }
}

extension CollaborationTests {
    @Test func learningOwnershipAfterOpeningUsesTheIncomingOwnerSetForImport() async throws {
        let model = try await model(), owner = GlossIdentity(author: .new(),name: "Alex")
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let remote = GlossNote(id: .new(),author: owner.author,via: GlossVia(agent: "Codex"),createdAt: at,updatedAt: at,iteration: 0,anchor: .wholeFile,body: "Question",color: .orange)
        let bundle = GlossNoteBundle(note: remote,events: [.sent(remote.id,by: owner.author,review: true,at: at),.resolved(remote.id,by: owner.author,outcome: .done,at: at+1),GlossEvent(note: remote.id,author: owner.author,type: .accepted,at: at+2)])
        let (folder,url) = try await package(owner: owner,notes: [bundle])
        defer { try? FileManager.default.removeItem(at: folder) }
        var participant = GlossSyncStatus(); participant.isShared = true; participant.role = .participant; participant.canWrite = true
        let initialStatus = participant; model.statusReader = { _ in initialStatus }
        await model.open(url)
        let review = try #require(model.reviews.first)
        #expect(!review.isOwner)
        #expect(try await model.store.notes(for: review.documentID).first?.reviewRequested == false)
        let author = model.settings.authorID
        try await Task.detached {
            let info = url.appendingPathComponent("Info.json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: info)) as? [String: Any])
            json["ownerAuthors"] = [owner.author.rawValue,author.rawValue].sorted()
            try JSONSerialization.data(withJSONObject: json,options: [.sortedKeys]).write(to: info,options: .atomic)
        }.value
        var nativeOwner = participant; nativeOwner.role = .owner
        let upgradedStatus = nativeOwner; model.statusReader = { _ in upgradedStatus }
        await model.retry(review)
        #expect(review.isOwner)
        #expect(try await model.store.indexedReviews().first?.isOwner == true)
        let note = try #require(try await model.store.notes(for: review.documentID).first)
        #expect(note.reviewRequested && note.acceptedAt == at+2)
        await model.stop()
    }
}

extension CollaborationTests {
    @Test func startupOnlyOpensDownloadedIndexedReviewsAndLeavesDeferredOnesAlone() async throws {
        let model = try await model()
        let (folder,url) = try await package(owner: model.settings.collaborationIdentity)
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let original = try #require(model.reviews.first)
        let unavailable = original.snapshot.info.instance
        await model.stop()
        let next = CollaborationModel(store: model.store,settings: model.settings)
        next.isDownloaded = { _ in false }
        await next.start()
        #expect(next.reviews.isEmpty && next.error == nil)
        #expect(try await next.store.indexedReviews().first?.instance == unavailable)
        await next.open(url)
        #expect(next.reviews.count == 1)
        await next.stop()
    }
    @Test func deletedReviewIsRemovedWithoutLosingItsPrivateNotes() async throws {
        let model = try await model()
        let (folder,url) = try await package(owner: model.settings.collaborationIdentity)
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        let privateNote = try await model.store.createNote(documentID: review.documentID,anchor: .wholeFile,body: "Keep my input",color: .yellow)
        var removed = false
        model.removedReview = { _ in removed = true }
        await model.receive(.deleted,in: review)
        #expect(model.reviews.isEmpty && removed)
        #expect(try await model.store.indexedReviews().isEmpty)
        #expect(try await model.store.note(privateNote.id)?.body == "Keep my input")
        await model.stop()
    }
    @Test func aConfirmedInvalidIndexedPackageIsRemovedWithoutALaunchAlert() async throws {
        let model = try await model()
        let (folder,url) = try await package(owner: model.settings.collaborationIdentity)
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        let privateNote = try await model.store.createNote(documentID: review.documentID,anchor: .wholeFile,body: "Private",color: .green)
        await model.stop()
        try FileManager.default.removeItem(at: url.appendingPathComponent("Info.json"))
        let next = CollaborationModel(store: model.store,settings: model.settings)
        next.isDownloaded = { _ in true }
        await next.start()
        #expect(next.reviews.isEmpty && next.error == nil)
        #expect(try await next.store.indexedReviews().isEmpty)
        #expect(try await next.store.note(privateNote.id) != nil)
        await next.stop()
    }
    @Test func firstShareKeepsOwnerCommentAndColorEditsMadeDuringPreparation() async throws {
        let model = try await model()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlossFirstShare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("README.md")
        try Data("# Saved\n".utf8).write(to: path)
        let source = DocumentSession(hostID: .local,path: path.path,fileSystem: LocalFileSystem(),noteStore: model.store)
        await source.open(); defer { source.close() }
        let document = try #require(source.document)
        let sent = try await model.store.createNote(documentID: document.id,anchor: .wholeFile,body: "Delivered comment",color: .yellow)
        _ = try await model.store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [sent.id],outcome: .delivered,carriedNotes: [sent])
        model.sourceFileSystem = { _ in LocalFileSystem() }
        model.reviewsFolder = { folder.appendingPathComponent("Reviews") }
        model.didCreateReview = { _ in
            try await model.store.updateBody(sent.id,body: "Private edit during preparation")
            try await model.store.updateColor(sent.id,color: .green)
        }
        await model.prepareShare(source,copy: false,browser: WebBrowserController(),portableSource: .file(name: "README.md",git: nil))
        let review = try #require(model.reviews.first)
        let current = try #require(try await model.store.note(sent.id))
        #expect(review.snapshot.notes.first?.body == sent.body && review.snapshot.notes.first?.color == sent.color.rawValue)
        #expect(current.body == "Private edit during preparation" && current.color == .green && current.hasUnpublishedChanges)
        await model.stop()
    }
    @Test func unchangedOwnerSynchronizationDoesNotCoordinateAClosedSession() async throws {
        let model = try await model()
        let (folder,url) = try await package(owner: model.settings.collaborationIdentity)
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        await model.stop()
        await model.synchronizeOwnerChanges()
        #expect(review.error == nil)
    }
    @Test func ownerSynchronizationClearsAnErrorAndDoesNotRepeatItsPublication() async throws {
        let model = try await model()
        let (folder,url) = try await package(owner: model.settings.collaborationIdentity)
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        let document = try await model.store.upsertDocument(hostID: .local,path: folder.appendingPathComponent("README.md").path,kind: .markdown,fingerprint: Fingerprint())
        try await model.store.linkReviewOriginal(review.id,to: document.id,baseline: Data("# Captured\n".utf8))
        await model.relink(review,to: document.id)
        _ = try await model.store.askUser(documentID: document.id,anchor: .wholeFile,question: "Which color?",author: "Codex")
        review.error = "Old failure"
        await model.synchronizeOwnerChanges()
        #expect(review.error == nil && review.snapshot.notes.count == 1)
        let before = review.snapshot
        await model.stop()
        await model.synchronizeOwnerChanges()
        #expect(review.error == nil)
        #expect(review.snapshot.events == before.events && review.snapshot.messages == before.messages)
    }
    @Test func openAndMergedEventsRunTheArchitectConsolidationContract() async throws {
        let model = try await model()
        let calls = Synchronization.Mutex<[Bool]>([])
        model.consolidateReviews = { _, resolve in calls.withLock { $0.append(resolve) } }
        let (folder,url) = try await package(owner: model.settings.collaborationIdentity)
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        let report = try await Task.detached { try GlossMerge.merge([],into: url) }.value
        await model.receive(.merged(report),in: review)
        #expect(calls.withLock { $0 } == [true,false])
        #expect(review.notice == "Review updates combined")
        model.consolidateReviews = { _, _ in throw GlossPackageError.notAllowed("Fixture merge unavailable") }
        await model.open(url)
        #expect(review.error?.contains("Fixture merge unavailable") == true && model.error == nil)
        let duplicate = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " 2.gloss")
        try FileManager.default.copyItem(at: url,to: duplicate)
        let usedURLs = Synchronization.Mutex<[URL]>([])
        model.consolidateReviews = { session, _ in
            usedURLs.withLock { $0.append(session.url) }
            throw GlossPackageError.notAllowed("Fixture merge unavailable")
        }
        await model.open(duplicate)
        #expect(model.reviews.count == 1 && review.session.url == url)
        #expect(usedURLs.withLock { $0 } == [url])
        #expect(review.error?.contains("Fixture merge unavailable") == true && model.error == nil)
        await model.receive(.merged(report),in: review)
        #expect(review.error?.contains("Fixture merge unavailable") == true && model.error == nil)
        await model.stop()
    }
}

extension CollaborationTests {
    @Test func reopeningARemovedReviewKeepsTheOwnersOriginalAndParticipantsPrivateDrafts() async throws {
        for isOwner in [true,false] {
            let model = try await model()
            let author = isOwner ? model.settings.collaborationIdentity : GlossIdentity(author: .new(),name: "Morgan")
            let remote = GlossNote(id: .new(),author: author.author,createdAt: Date(),updatedAt: Date(),iteration: 0,anchor: .wholeFile,body: "Published",color: .green)
            let (folder,url) = try await package(owner: author,notes: [GlossNoteBundle(note: remote)])
            defer { try? FileManager.default.removeItem(at: folder) }
            await model.open(url)
            let review = try #require(model.reviews.first)
            if isOwner {
                let document = try await model.store.upsertDocument(hostID: .local,path: folder.appendingPathComponent("README.md").path,kind: .markdown,fingerprint: Fingerprint())
                try await model.store.linkReviewOriginal(review.id,to: document.id,baseline: Data("# Captured\n".utf8))
                await model.relink(review,to: document.id)
            }
            let documentID = review.documentID
            let draft = try await model.store.createNote(documentID: documentID,anchor: .wholeFile,body: "Private draft",color: .yellow)
            let ids = try await model.store.notes(for: documentID).map(\.id)
            await model.receive(.deleted,in: review)
            await model.open(url)
            let restored = try #require(model.reviews.first)
            #expect(restored.documentID == documentID && restored.isOwner == isOwner)
            #expect(try await model.store.notes(for: documentID).map(\.id) == ids)
            #expect(try await model.store.note(draft.id)?.body == "Private draft")
            await model.stop()
        }
    }
}

extension CollaborationTests {
    @Test func initialAgentQuestionPublicationKeepsAHumanCommentAndColorPrivate() async throws {
        let model = try await model()
        let (folder,url) = try await package(owner: model.settings.collaborationIdentity)
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.open(url)
        let review = try #require(model.reviews.first)
        let document = try await model.store.upsertDocument(hostID: .local,path: folder.appendingPathComponent("README.md").path,kind: .markdown,fingerprint: Fingerprint())
        try await model.store.linkReviewOriginal(review.id,to: document.id,baseline: Data("# Captured\n".utf8))
        await model.relink(review,to: document.id)
        let question = try await model.store.askUser(documentID: document.id,anchor: .wholeFile,question: "Which color?",author: "Codex")
        try await model.store.updateBody(question.id,body: "Private comment")
        try await model.store.updateColor(question.id,color: .green)
        #expect(try await model.store.agentNote(question.id)?.body == "")
        await model.synchronizeOwnerChanges()
        let published = try #require(review.snapshot.notes.first)
        #expect(published.body == "" && published.noteColor == question.color)
        await model.retry(review)
        let current = try #require(try await model.store.note(question.id))
        #expect(current.body == "Private comment" && current.color == .green && current.hasUnpublishedChanges)
        await model.stop()
    }
}

extension CollaborationTests {
    @Test func startingCollaborationDoesNotWaitForAReviewProbe() async throws {
        let app = AppModel(launchOptions: AppLaunchOptions(arguments: ["app","--reset-db"]))
        let collaboration = app.collaboration
        let document = try await collaboration.store.upsertDocument(hostID: .gloss,path: "/fixture/README.md",kind: .markdown,fingerprint: Fingerprint())
        let info = GlossInfo(id: .new(),instance: .new(),createdAt: Date(),ownerAuthor: .new(),kind: .markdown,title: "README.md",source: .file(name: "README.md",git: nil),current: GlossCurrent(hash: Data("saved".utf8).sha256Hex,iteration: 0,capturedAt: Date()))
        try await collaboration.store.indexReview(info,url: URL(fileURLWithPath: "/tmp/Indexed.gloss"),documentID: document.id,isOwner: false)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        collaboration.isDownloaded = { _ in entered.signal(); _ = release.wait(timeout: .now()+10); return false }
        app.startCollaboration()
        let waitForProbe: @Sendable () -> Bool = { entered.wait(timeout: .now()+5) == .success }
        let reached = await Task.detached { waitForProbe() }.value
        #expect(reached && collaboration.reviews.isEmpty)
        release.signal()
        await collaboration.stop()
    }
}
