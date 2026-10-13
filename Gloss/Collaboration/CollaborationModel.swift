import AppKit
import Core
import Observation
import Viewers
import Integrations
import WebKit

@MainActor @Observable
final class ReviewContext: Identifiable {
    let session: GlossReviewSession
    var documentID: DocumentID
    let capturePath: String
    var historyFacts: [Int: JSONValue] = [:]
    var snapshot: GlossSnapshot
    var status: GlossSyncStatus
    var unread: Set<String> = []
    var error: String?
    var notice: String?
    var receivedNoteIDs: [NoteID] = []
    var noteMap: [NoteID: NoteID] = [:]
    var messageMap: [MessageID: MessageID] = [:]
    var isPublishing = false
    var id: InstanceID { snapshot.info.instance }
    var isCopy: Bool { snapshot.info.origin != nil }
    var isOwner: Bool { !isCopy && snapshot.info.isOwner(session.identity.author) && status.role != .participant }
    var ownerName: String { CollaborationModel.displayName(snapshot.author(snapshot.info.ownerAuthor)?.name) }
    var title: String { snapshot.info.title }
    var locationTitle: String { title + (isCopy ? " · Copy" : (isOwner ? " · Shared by You" : " · Shared by \(ownerName)")) }
    /// Unknown permission is not authorization. Local unshared owner packages remain writable.
    var canWrite: Bool { !isCopy && (status.canWrite == true || (isOwner && !status.isShared)) }
    var isParticipant: Bool { !isOwner && !isCopy }
    init(session: GlossReviewSession, documentID: DocumentID, capturePath: String, snapshot: GlossSnapshot, status: GlossSyncStatus) {
        self.session = session; self.documentID = documentID; self.capturePath = capturePath; self.snapshot = snapshot; self.status = status
    }
}

/// All app publication goes through one queue. It captures exact local values before leaving the UI actor.
@MainActor @Observable
final class CollaborationModel {
    let store: NoteStore
    let settings: SettingsStore
    let fileSystem = ReviewFileSystem()
    private(set) var reviews: [ReviewContext] = []
    var isSharePresented = false
    var isPopoverPresented = false
    var preparing = false
    var error: String?
    var needsSave = false
    var excludedNotesCount = 0
    var shareURL: URL?
    var shareIsCopy = false
    var sharingIsActive = false
    @ObservationIgnored var statusReader: @Sendable (GlossReviewSession) -> GlossSyncStatus = { $0.status() }
    @ObservationIgnored var isDownloaded: @Sendable (URL) -> Bool = { url in
        var url = url; url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { return false }
        guard let ubiquitous = values.isUbiquitousItem else { return false }
        if ubiquitous { return values.ubiquitousItemDownloadingStatus == .current }
        return FileManager.default.fileExists(atPath: url.path)
    }
    @ObservationIgnored var consolidateReviews: @Sendable (GlossReviewSession, Bool) throws -> Void = { session, resolve in
        for duplicate in session.duplicates() { _ = try session.absorbDuplicate(duplicate) }
        if resolve { _ = try session.resolveConflictsNow() }
    }
    @ObservationIgnored var reviewsFolder: @Sendable () throws -> URL = { try GlossLocations.reviewsFolder() }
    @ObservationIgnored var didCreateReview: (GlossReviewSession) async throws -> Void = { _ in }
    @ObservationIgnored var removedReview: (ReviewContext) -> Void = { _ in }
    @ObservationIgnored var showReview: (ReviewContext) -> Void = { _ in }
    @ObservationIgnored var sourceSession: (DocumentID) -> DocumentSession? = { _ in nil }
    @ObservationIgnored var captureSource: (DocumentID) async throws -> (GlossContent,JSONValue?) = { _ in throw FileSystemError.io("Open the original document to refresh its capture") }
    @ObservationIgnored var sourceFileSystem: (HostID) -> (any FileSystemProvider)? = { _ in nil }
    @ObservationIgnored var revealNotes: (ReviewContext, [NoteID]) -> Void = { _, _ in }
    @ObservationIgnored private var watchers: [InstanceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var localWatcher: Task<Void, Never>?
    @ObservationIgnored private var operations: Task<Void, Never>?
    @ObservationIgnored private var stopped = false
    init(store: NoteStore, settings: SettingsStore) { self.store = store; self.settings = settings }

    nonisolated static func displayName(_ name: String?) -> String {
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? "Unnamed contributor" : clean
    }
    func context(for documentID: DocumentID?) -> ReviewContext? { reviews.first { $0.documentID == documentID } }
    func context(path: String) -> ReviewContext? { reviews.first { $0.capturePath == path } }

    /// Serializes imports and writes as well as local stamps, so a presenter echo cannot overwrite pending input.
    private func enqueue(_ action: @escaping @MainActor () async -> Void) async {
        let previous = operations
        let next = Task { await previous?.value; await action() }
        operations = next
        await next.value
    }
    func start() async {
        guard !stopped, !Task.isCancelled else { return }
        let indexed = (try? await store.indexedReviews()) ?? []
        let downloaded = isDownloaded
        for review in indexed {
            guard !Task.isCancelled else { return }
            if await Task.detached(operation: { downloaded(review.url) }).value { await open(review.url, reveal: false) }
        }
        guard !stopped, !Task.isCancelled else { return }
        startObservingLocalChanges()
    }
    func open(_ url: URL, reveal: Bool = true) async {
        guard !stopped, !Task.isCancelled else { return }
        if !settings.loaded { await settings.load() }
        await enqueue { [self] in
            var openedSession: GlossReviewSession?
            var attemptedURL = url
            do {
                let identity = settings.collaborationIdentity
                let created = try await Task.detached { try GlossReviewSession(url: url, identity: identity) }.value
                openedSession = created
                let existingInstance = reviews.first { $0.id == created.info.instance }
                let session = existingInstance?.session ?? created
                if existingInstance != nil {
                    await Task.detached { created.close() }.value
                    openedSession = nil
                }
                attemptedURL = session.url
                guard !stopped, !Task.isCancelled else { throw CancellationError() }
                let consolidate = consolidateReviews
                let read = try await Task.detached {
                    var mergeError: String?
                    do { try consolidate(session, true) }
                    catch { mergeError = error.userMessage }
                    return (try session.snapshot(),mergeError)
                }.value
                let status = await readStatus(session)
                let snapshot = try await adoptOwnership(session,snapshot: read.0,status: status)
                guard !stopped, !Task.isCancelled else { throw CancellationError() }
                if let existing = reviews.first(where: { $0.id == snapshot.info.instance }) {
                    try await adopt(snapshot,into: existing)
                    if let error = read.1 { existing.error = error }
                    if let openedSession { await Task.detached { openedSession.close() }.value }
                    openedSession = nil
                    if reveal { showReview(existing) }
                    return
                }
                let indexed = try await store.indexedReviews().first { $0.instance == snapshot.info.instance }
                let capturePath = "/\(snapshot.info.instance.rawValue)/\(snapshot.info.title)"
                let document: Core.Document
                let retainedID = try await store.reviewDocumentID(snapshot.info.instance)
                if let id = indexed?.documentID ?? retainedID, let original = try await store.document(id) { document = original }
                else { document = try await store.upsertDocument(hostID: .gloss, path: capturePath, kind: snapshot.info.documentKind ?? .file, fingerprint: Fingerprint()) }
                let context = ReviewContext(session: session, documentID: document.id, capturePath: capturePath, snapshot: snapshot, status: status)
                try await store.indexReview(snapshot.info,url: session.url,documentID: document.id,isOwner: context.isOwner)
                try await adopt(snapshot, into: context)
                if let error = read.1 { context.error = error }
                reviews.append(context)
                openedSession = nil
                observe(context)
                if reveal { showReview(context) }
            } catch {
                if let openedSession { await Task.detached { openedSession.close() }.value }
                // A complete local package that cannot open is a stale index entry, not a launch alert.
                let downloaded = isDownloaded, failedURL = attemptedURL
                if await Task.detached(operation: { downloaded(failedURL) }).value,
                   let failure = error as? GlossPackageError {
                    switch failure {
                    case .notAPackage, .unreadable, .unsafePath:
                        if let indexed = try? await store.indexedReviews().first(where: { $0.url == failedURL }) {
                            if let context = reviews.first(where: { $0.id == indexed.instance }) { await remove(context) }
                            else { try? await store.removeReview(indexed.instance) }
                        }
                    default: break
                    }
                }
                if reveal, !(error is CancellationError), !stopped { self.error = error.userMessage }
            }
        }
    }
    func remove(_ context: ReviewContext) async {
        do { try await store.removeReview(context.id) }
        catch { context.error = error.userMessage; return }
        watchers.removeValue(forKey: context.id)?.cancel()
        reviews.removeAll { $0 === context }
        removedReview(context)
        let session = context.session
        await Task.detached { session.close() }.value
    }
    private func observe(_ context: ReviewContext) {
        let session = context.session
        watchers[context.id] = Task { [weak self, weak context] in
            let changes = await Task.detached { session.changes() }.value
            for await change in changes {
                guard !Task.isCancelled, let self, let context else { return }
                await self.receive(change, in: context)
            }
        }
    }
    func receive(_ change: GlossReviewChange, in context: ReviewContext) async {
        await enqueue { [self] in
            guard reviews.contains(where: { $0 === context }) else { return }
            let session = context.session
            switch change {
            case .updated:
                do {
                    // A stream's cached initial snapshot may arrive after a manual refresh/publication.
                    // Treat it as a signal and read the latest coordinated tree before importing.
                    let session = context.session
                    let snapshot = try await Task.detached { try session.snapshot() }.value
                    let previous = Set(context.snapshot.notes.map(\.id))
                    try await adopt(snapshot, into: context)
                    let incoming = snapshot.notes.filter { !previous.contains($0.id) && $0.author != settings.authorID }
                    if !incoming.isEmpty {
                        let names = Set(incoming.map { Self.displayName(snapshot.author($0.author)?.name) }).sorted().joined(separator: ", ")
                        context.notice = "\(incoming.count.counted("note")) from \(names)"
                        context.receivedNoteIDs = incoming.compactMap { context.noteMap[$0.id] }
                    }
                } catch { context.error = error.userMessage }
            case .status(let status):
                let wasOwner = context.isOwner
                context.status = status
                do {
                    let snapshot = try await adoptOwnership(session,snapshot: context.snapshot,status: status)
                    if wasOwner != context.isOwner || (!context.snapshot.info.isOwner(settings.authorID) && snapshot.info.isOwner(settings.authorID)) { try await adopt(snapshot,into: context) }
                    try await store.indexReview(context.snapshot.info,url: session.url,documentID: context.documentID,isOwner: context.isOwner)
                } catch { context.error = error.userMessage }
            case .moved(let url):
                try? await store.indexReview(context.snapshot.info, url: url, documentID: context.documentID, isOwner: context.isOwner)
            case .deleted: await remove(context)
            case .failed(let message): context.error = message
            case .merged:
                do {
                    let consolidate = consolidateReviews
                    let snapshot = try await Task.detached {
                        try consolidate(session, false)
                        return try session.snapshot()
                    }.value
                    try await adopt(snapshot, into: context)
                    context.notice = "Review updates combined"
                } catch { context.error = error.userMessage }
            }
        }
    }
    private func adopt(_ snapshot: GlossSnapshot, into context: ReviewContext) async throws {
        let session = context.session
        context.status = await readStatus(session)
        let snapshot = try await adoptOwnership(session,snapshot: snapshot,status: context.status)
        // A partial new pointer must never replace a complete capture.
        guard snapshot.hasCurrentContent else { context.error = "Downloading the review's content…"; return }
        let capture = try await Task.detached { try ReviewCapture.read(session,hash: snapshot.info.current.hash,kind: snapshot.info.documentKind,facts: snapshot.info.content) }.value
        let bytes = capture.0
        if let facts = capture.1 { context.historyFacts[snapshot.info.current.iteration] = facts }
        let prior = context.snapshot.info.current
        context.status = await readStatus(session)
        let isOwner = snapshot.info.origin == nil && snapshot.info.isOwner(settings.authorID) && context.status.role != .participant
        try await store.indexReview(snapshot.info,url: session.url,documentID: context.documentID,isOwner: isOwner)
        try await store.importReview(snapshot, documentID: context.documentID, identity: settings.authorID, isOwner: isOwner)
        context.noteMap = try await store.reviewNoteMap(context.id)
        context.messageMap = try await store.reviewMessageMap(context.id)
        context.snapshot = snapshot
        context.status = await readStatus(session)
        let seen = try await store.seenReviewRecords(context.id)
        context.unread = recordIDs(snapshot, excluding: settings.authorID).subtracting(seen)
        context.error = nil
        await fileSystem.adopt(bytes,path: context.capturePath,at: snapshot.info.current.capturedAt,iteration: snapshot.info.current.iteration,images: capture.2)
        var history: [Int: Data] = [:]
        for iteration in snapshot.iterations where iteration.endedAt != nil {
            guard let retained = try? await Task.detached(operation: { try ReviewCapture.read(session,hash: iteration.snapshot,kind: snapshot.info.documentKind,facts: nil) }).value else { continue }
            history[iteration.number] = retained.0
            if let facts = retained.1 { context.historyFacts[iteration.number] = facts }
            await fileSystem.retainImages(retained.2,path: context.capturePath,iteration: iteration.number)
        }
        try await store.importReviewSnapshots(history,documentID: context.documentID)
        if prior.hash != snapshot.info.current.hash || prior.iteration != snapshot.info.current.iteration { context.notice = "Content updated · Iteration \(snapshot.info.current.iteration)" }
        for note in snapshot.notes {
            guard let localID = context.noteMap[note.id] else { continue }
            let existing = try await store.attachments(for: localID)
            for ref in note.attachments ?? [] {
                let data = try await Task.detached { try session.readFile(ref.path) }.value
                let url = AttachmentCache.notesRoot.appendingPathComponent(context.id.rawValue).appendingPathComponent(data.sha256Hex + ".png")
                if existing.contains(where: { $0.localPath == url.path }) { continue }
                try await Task.detached { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: url, options: .atomic) }.value
                let attachment = Attachment(id: .new(), noteID: localID, kind: AttachmentKind(rawValue: ref.kind) ?? .crop, localPath: url.path, width: ref.width, height: ref.height)
                _ = try await store.addAttachment(noteID: attachment.noteID, kind: attachment.kind, localPath: attachment.localPath, width: attachment.width, height: attachment.height)
            }
        }
    }
    private func recordIDs(_ snapshot: GlossSnapshot, excluding author: AuthorID) -> Set<String> {
        Set(snapshot.notes.filter { $0.author != author }.map { $0.id.rawValue + ":" + $0.rev }
            + snapshot.messages.filter { $0.author != author }.map { $0.id.rawValue }
            + snapshot.events.filter { $0.author != author }.map { $0.id.rawValue }
            + (snapshot.info.isOwner(author) ? [] : ["content:" + snapshot.info.current.hash]))
    }
    func markAllSeen(_ context: ReviewContext) async {
        let shown = context.unread
        try? await store.markReviewRecordsSeen(shown, instance: context.id)
        context.unread.subtract(shown)
    }
    func revealReceived(_ context: ReviewContext) {
        revealNotes(context, context.receivedNoteIDs)
    }
    func revealed(_ note: Note, includeThread: Bool = false) {
        guard let context = context(for: note.documentID), let remote = context.noteMap.first(where: { $0.value == note.id })?.key else { return }
        let snapshot = context.snapshot
        let notes = snapshot.notes.filter { $0.id == remote }.map { $0.id.rawValue + ":" + $0.rev }
        let turns: [String]
        if includeThread { turns = snapshot.messages.filter { $0.note == remote }.map { $0.id.rawValue } }
        else { turns = snapshot.messages.last(where: { $0.note == remote }).map { [$0.id.rawValue] } ?? [] }
        let events = snapshot.events.last(where: { $0.note == remote }).map { [$0.id.rawValue] } ?? []
        let shown = Set(notes + turns + events)
        Task { try? await store.markReviewRecordsSeen(shown, instance: context.id); context.unread.subtract(shown) }
    }

    nonisolated private static func publishOwn(_ bundles: [GlossNoteBundle],to session: GlossReviewSession) throws {
        let report = try session.publish(bundles)
        guard report.notesRefused.isEmpty else { throw GlossPackageError.notAllowed("Some notes couldn't be sent. Your changes are saved here.") }
    }

    nonisolated static func shouldAdoptOwnership(_ snapshot: GlossSnapshot,author: AuthorID,status: GlossSyncStatus) -> Bool {
        let owned = status.isShared ? status.role == .owner : status.isInICloud && status.role == nil
        return snapshot.info.origin == nil && !snapshot.info.isOwner(author) && owned
    }

    private func adoptOwnership(_ session: GlossReviewSession,snapshot: GlossSnapshot,status: GlossSyncStatus) async throws -> GlossSnapshot {
        guard Self.shouldAdoptOwnership(snapshot,author: settings.authorID,status: status) else { return snapshot }
        return try await Task.detached { _ = try session.adoptOwnership(); return try session.snapshot() }.value
    }

    nonisolated private static func updateName(_ session: GlossReviewSession,to name: String, current: String?) throws {
        if current != name { try session.setName(name) }
    }

    private func ownsInput(_ contributor: String?) -> Bool { contributor == nil || contributor == settings.authorID.rawValue }

    func canEdit(_ note: Note) -> Bool {
        guard let review = context(for: note.documentID) else { return true }
        return (review.canWrite || (review.isCopy && note.publishedAt == nil)) && (note.contributorID == nil || note.contributorID == settings.authorID.rawValue)
    }
    func canChange(_ note: Note) -> Bool {
        guard let review = context(for: note.documentID) else { return true }
        return review.canWrite || (review.isCopy && note.publishedAt == nil)
    }
    func canDelete(_ note: Note) -> Bool {
        guard let review = context(for: note.documentID) else { return true }
        return (review.canWrite && review.isOwner) || canEdit(note)
    }
    func isSendable(_ note: Note) -> Bool {
        guard let review = context(for: note.documentID), !review.isOwner else { return note.isSendable || note.hasUnpublishedChanges }
        guard review.canWrite else { return false }
        return ((note.contributorID == nil || note.contributorID == settings.authorID.rawValue) && (note.publishedAt == nil || note.hasUnpublishedChanges)) || note.hasUnsentFollowUps
    }

    func publish(_ ids: [NoteID], in context: ReviewContext) async {
        await enqueue { [self] in
            guard context.canWrite else { context.error = context.isCopy ? "This copy has no owner to send to." : "You can view this review only. Your notes are saved here."; return }
            context.isPublishing = true
            defer { context.isPublishing = false }
            do {
                var notes: [Note] = []
                for id in ids { if let note = try await store.note(id) { notes.append(note) } }
                guard notes.count == ids.count else { throw GlossPackageError.notAllowed("A note was deleted") }
                let threads = try await store.messages(for: ids)
                let date = Date()
                var bundles: [GlossNoteBundle] = []
                var turns: [GlossMessage] = []
                var carried: [NoteMessage] = []
                for note in notes {
                    guard note.documentID == context.documentID else { throw GlossPackageError.notAllowed("Send stays in this review") }
                    let own = note.contributorID == nil || note.contributorID == settings.authorID.rawValue
                    let remoteID = context.noteMap.first { $0.value == note.id }?.key ?? note.id
                    var messages = (threads[note.id] ?? []).filter { ownsInput($0.contributorID) }
                    let unsent = messages.filter { !$0.isSent && $0.author == .user }
                    carried += unsent
                    for i in messages.indices where messages[i].author == .user && !messages[i].isSent { messages[i].sentAt = date }
                    let existingRemote = Set(context.snapshot.messages.map(\.id))
                    let attachments = try await store.attachments(for: note.id)
                    let files = try await Task.detached { try attachments.map { ($0, try Data(contentsOf: URL(fileURLWithPath: $0.localPath))) } }.value
                    var bundle = GlossNoteBundle(note: note, messages: messages, attachments: files, identity: settings.collaborationIdentity, isOwner: context.isOwner, sentAt: nil)
                    bundle.note.id = remoteID
                    bundle.messages = bundle.messages.filter { !existingRemote.contains($0.id) }
                    for i in bundle.messages.indices {
                        bundle.messages[i].note = remoteID
                        if let reply = bundle.messages[i].inReplyTo, let remote = context.messageMap.first(where: { $0.value == reply })?.key { bundle.messages[i].inReplyTo = remote }
                    }
                    if own { bundles.append(bundle) } else { turns += bundle.messages }
                }
                let session = context.session
                let reopenEvents = notes.compactMap { note -> GlossEvent? in
                    let remote = context.noteMap.first { $0.value == note.id }?.key ?? note.id
                    guard context.snapshot.folded().first(where: { $0.id == remote })?.status == .resolved,
                          carried.contains(where: { $0.noteID == note.id }) else { return nil }
                    return GlossEvent(note: remote,author: settings.authorID,type: .reopened,at: date)
                }
                let publishBundles = bundles, publishTurns = turns
                let name = settings.yourName, currentName = context.snapshot.author(settings.authorID)?.name
                try await Task.detached { try Self.updateName(session,to: name,current: currentName); try Self.publishOwn(publishBundles,to: session)
                    try session.post(publishTurns); try session.record(reopenEvents) }.value
                try await store.recordReviewPublication(notes.filter { $0.contributorID == nil || $0.contributorID == settings.authorID.rawValue }, messages: carried,
                                                       instance: context.id, identity: settings.collaborationIdentity, at: date)
                let snapshot = try await Task.detached { try session.snapshot() }.value
                try await adopt(snapshot, into: context)
                context.notice = context.status.isUploaded ? "Sent \(notes.count.counted("note")) to the review" : "\(notes.count.counted("note")) saved · Waiting for iCloud"
            } catch { context.error = error.userMessage }
        }
    }

    /// Explicit shared state changes are immediate; drafts remain local.
    func change(_ note: Note, type: GlossEventType) async -> Bool {
        guard let context = context(for: note.documentID) else { return true }
        if note.publishedAt == nil, context.isCopy { return true }
        guard context.canWrite, type != .accepted || context.isOwner,
              type != .deleted || canDelete(note) else { context.error = "You don't have permission for this action."; return false }
        guard let remoteID = context.noteMap.first(where: { $0.value == note.id })?.key else { return true }
        var success = false
        await enqueue { [self] in
            do {
                let event = GlossEvent(note: remoteID, author: settings.authorID, type: type, at: Date())
                let session = context.session, name = settings.yourName, currentName = context.snapshot.author(settings.authorID)?.name
                try await Task.detached { try Self.updateName(session,to: name,current: currentName); try session.record([event]) }.value
                success = true
            } catch { context.error = error.userMessage }
        }
        return success
    }

    private func startObservingLocalChanges() {
        guard !stopped, localWatcher == nil else { return }
        localWatcher = Task { [weak self] in
            guard let self else { return }
            do {
                for try await _ in store.observeDocumentsWithNotes() {
                    guard !Task.isCancelled else { return }
                    await synchronizeOwnerChanges()
                }
            } catch { self.error = error.userMessage }
        }
    }
    func synchronizeOwnerChanges() async {
        await enqueue { [self] in
            for context in reviews where context.isOwner && context.canWrite {
                do {
                    let notes = try await store.notes(for: context.documentID)
                    let sent = try await store.sharedNoteIDs()
                    let packageMessages = Set(context.snapshot.messages.map(\.id))
                    let packageEvents = Set(context.snapshot.events.map(\.id))
                    let folded = context.snapshot.folded()
                    var newNotes: [GlossNoteBundle] = [], events: [GlossEvent] = [], turns: [GlossMessage] = []
                    var newPublications: [Note] = []
                    for note in notes where sent.contains(note.id) && (note.publishedAt != nil || note.author != nil) {
                        let last = try await store.lastSend(for: note.id)
                        let messages = try await store.messages(for: note.id).filter { ownsInput($0.contributorID) }
                        let remote = context.noteMap.first { $0.value == note.id }?.key ?? note.id
                        let old = folded.first { $0.id == remote }
                        if old == nil, !ownsInput(note.contributorID) { continue }
                        var exported = note
                        if let old { exported.body = old.note.body; exported.color = old.note.noteColor }
                        else if let delivered = try await store.agentNote(note.id) { exported.body = delivered.body; exported.color = delivered.color }
                        var bundle = GlossNoteBundle(note: exported, messages: messages, attachments: [], identity: settings.collaborationIdentity, isOwner: true,
                                                     sentAt: last?.outcome == "delivered" ? last?.sentAt : nil, reviewRequested: note.reviewRequested, resolvedAt: note.resolvedAt)
                        bundle.note.id = remote
                        bundle.messages.removeAll { packageMessages.contains($0.id) }
                        bundle.messages.indices.forEach { bundle.messages[$0].note = remote }
                        if let old, old.anchor != note.anchor, let turn = messages.last(where: { $0.kind == .moved }), let move = turn.move {
                            var event = try GlossEvent.moved(remote,by: settings.authorID,to: note.anchor,removed: move.removed,at: turn.createdAt)
                            event.id = .derived(note: remote,type: .moved,author: settings.authorID,at: turn.createdAt)
                            bundle.events.append(event)
                        }
                        bundle.events.indices.forEach { bundle.events[$0].note = remote }
                        bundle.events.removeAll { packageEvents.contains($0.id) || (note.resolveAgent == nil && $0.eventType == .resolved) }
                        if old == nil { newNotes.append(bundle); newPublications.append(exported) }
                        else { events += bundle.events; turns += bundle.messages }
                    }
                    let document = try await store.document(context.documentID)
                    let next = document.flatMap { $0.hostID != .gloss && $0.currentIteration > context.snapshot.info.current.iteration && sourceFileSystem($0.hostID) != nil ? $0 : nil }
                    let name = settings.yourName, currentName = context.snapshot.author(settings.authorID)?.name
                    guard !newNotes.isEmpty || !events.isEmpty || !turns.isEmpty || next != nil || name != currentName else { continue }
                    var capture: (GlossContent, JSONValue?)?
                    if let next { capture = try await captureSource(next.id) }
                    let captured = capture
                    let session = context.session, bundles = newNotes, sharedEvents = events, sharedTurns = turns
                    let fresh = try await Task.detached {
                        try Self.updateName(session,to: name,current: currentName)
                        if !bundles.isEmpty { try Self.publishOwn(bundles,to: session) }
                        if !sharedEvents.isEmpty { try session.record(sharedEvents) }
                        if !sharedTurns.isEmpty { try session.post(sharedTurns) }
                        if let next, let captured { _ = try session.publishIteration(next.currentIteration,content: captured.0,contentFacts: captured.1,gitCommit: nil,name: nil,at: Date()) }
                        return try session.snapshot()
                    }.value
                    if !newPublications.isEmpty {
                        try await store.recordReviewPublication(newPublications,messages: [],instance: context.id,identity: settings.collaborationIdentity,at: Date())
                    }
                    // Keep local resolutions intact while their rollover is pending.
                    context.snapshot = fresh
                    context.error = nil
                } catch { context.error = error.userMessage }
            }
        }
    }
}

extension CollaborationModel {
    func authorLabel(_ note: Note) -> String {
        guard let id = note.contributorID else { return "You" }
        let context = context(for: note.documentID)
        let name = id == settings.authorID.rawValue ? "You" : Self.displayName(note.contributorName)
        return name + (context?.snapshot.info.owners.contains(AuthorID(rawValue: id)) == true ? " · Owner" : "")
    }
    func turnAuthor(_ id: MessageID?, note: Note) -> String {
        guard let context = context(for: note.documentID), let id else { return "You" }
        let remote = context.messageMap.first { $0.value == id }?.key.rawValue ?? id.rawValue
        guard let turn = context.snapshot.messages.first(where: { $0.id.rawValue == remote }) else { return "You" }
        return (turn.author == settings.authorID ? "You" : Self.displayName(context.snapshot.author(turn.author)?.name))
            + (context.snapshot.info.isOwner(turn.author) ? " · Owner" : "")
    }

    func prepareShare(_ source: DocumentSession, copy: Bool, browser: WebBrowserController, portableSource: GlossSource) async {
        guard !preparing else { return }
        error = nil; shareURL = nil; excludedNotesCount = 0; needsSave = source.isDirty
        guard !source.isDirty else { return }
        if !settings.loaded { await settings.load() }
        preparing = true
        defer { preparing = false }
        do {
            var temporarySession: GlossReviewSession?
            var newSession: GlossReviewSession?
            defer {
                if let newSession {
                    let url = newSession.url
                    Task.detached { newSession.close(); try? FileManager.default.removeItem(at: url) }
                }
                if let temporarySession {
                    let folder = temporarySession.url.deletingLastPathComponent()
                    Task.detached { temporarySession.close(); try? FileManager.default.removeItem(at: folder) }
                }
            }
            let context: ReviewContext
            if let current = self.context(for: source.document?.id) {
                context = current
            } else {
                guard let opened = source.document, let document = try await store.document(opened.id) else { throw GlossPackageError.notAPackage("Wait for the document to finish opening") }
                let content: GlossContent
                let facts: JSONValue?
                if document.kind == .web, let html = source.html { (content,facts) = try await ReviewCapture.viewport(browser,expected: html) }
                else {
                    guard let provider = sourceFileSystem(document.hostID) else { throw FileSystemError.notFound(document.path) }
                    (content,facts) = try await ReviewCapture.saved(source,provider: provider,browser: browser)
                }
                guard !source.isDirty else { needsSave = true; return }
                let baseline: Data
                if document.kind == .web { baseline = Data((source.html?.source.text ?? "").utf8) }
                else {
                    switch content {
                    case .file(let data,_): baseline = data
                    case .folder(let files):
                        if let entry = facts?["document"]?.stringValue, let data = files[entry] { baseline = data }
                        else if let provider = sourceFileSystem(document.hostID) { baseline = try await provider.read(document.path) }
                        else { throw FileSystemError.notFound(document.path) }
                    }
                }
                try await store.recordIterationStart(documentID: document.id,content: baseline)
                let seed = GlossReviewSeed(title: document.fileName, kind: source.html == nil ? document.kind : .web, source: portableSource,
                                           content: content, contentFacts: facts, iteration: document.currentIteration, capturedAt: Date())
                let visible = try await store.sharedNoteIDs()
                var bundles: [GlossNoteBundle] = [], publishedNotes: [Note] = []
                for original in try await store.notes(for: document.id,iteration: document.currentIteration) where visible.contains(original.id) && original.iteration == document.currentIteration {
                    guard ownsInput(original.contributorID) else { excludedNotesCount += 1; continue }
                    guard let note = try await store.deliveredReviewNote(original.id) else { excludedNotesCount += 1; continue }
                    publishedNotes.append(note)
                    let turns = try await store.messages(for: note.id).filter { ownsInput($0.contributorID) }
                    let snapshots = try await store.agentResourceAttachments(note.id)
                    let files = snapshots.map { ($0.attachment,$0.data) }
                    let sent = try await store.lastSend(for: note.id)
                    bundles.append(GlossNoteBundle(note: note, messages: turns, attachments: files, identity: settings.collaborationIdentity,
                                                   isOwner: true, sentAt: sent?.outcome == "delivered" ? sent?.sentAt : nil, reviewRequested: note.reviewRequested, resolvedAt: note.resolvedAt))
                }
                let identity = settings.collaborationIdentity, exports = bundles
                let folderProvider = reviewsFolder
                let folder = try await Task.detached { copy ? FileManager.default.temporaryDirectory.appendingPathComponent("GlossShare-" + UUID().uuidString) : try folderProvider() }.value
                try await Task.detached { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }.value
                guard try await store.document(document.id)?.currentIteration == document.currentIteration else { throw GlossPackageError.notAllowed("The document started another iteration while preparing. Try sharing again.") }
                try Task.checkCancellation()
                let session = try await Task.detached { try GlossReviewSession.create(in: folder,seed: seed,notes: exports,identity: identity) }.value
                if copy { temporarySession = session } else { newSession = session }
                try await didCreateReview(session)
                try Task.checkCancellation()
                let snapshot = try await Task.detached { try session.snapshot() }.value
                let status = await readStatus(session)
                context = ReviewContext(session: session, documentID: document.id, capturePath: "/\(snapshot.info.instance.rawValue)/\(snapshot.info.title)", snapshot: snapshot, status: status)
                try Task.checkCancellation()
                guard try await store.document(document.id)?.currentIteration == document.currentIteration else { throw GlossPackageError.notAllowed("The document started another iteration while preparing. Try sharing again.") }
                if !copy {
                    // Once indexed this is a saved local review, even if invitation preparation is dismissed.
                    try await store.indexReview(snapshot.info, url: session.url, documentID: document.id, isOwner: true)
                    do {
                        try await store.recordReviewPublication(publishedNotes,messages: [],instance: context.id,identity: identity,at: Date())
                        try await adopt(snapshot, into: context)
                    } catch {
                        try? await store.removeReview(context.id)
                        throw error
                    }
                    reviews.append(context)
                    newSession = nil
                    observe(context); startObservingLocalChanges()
                }
            }
            if copy {
                let session = context.session
                let artifact = try await Task.detached { try session.makeCopy() }.value
                if Task.isCancelled { try? await Task.detached { try FileManager.default.removeItem(at: artifact.deletingLastPathComponent()) }.value; return }
                shareURL = artifact
            } else {
                let session = context.session
                context.status = await readStatus(session)
                guard context.status.isInICloud else { throw GlossPackageError.notAllowed("iCloud Drive is needed to collaborate. You can send a copy instead.") }
                guard context.status.isUploaded else { throw GlossPackageError.notAllowed("The review is waiting for iCloud. Try again once it has uploaded.") }
                try Task.checkCancellation()
                shareURL = session.url
            }
            shareIsCopy = copy
        } catch is CancellationError { shareURL = nil }
        catch { self.error = error.userMessage }
    }

    /// Publishes exactly the delivered packet's comment and carried answers, never edits made during delivery.
    func ownerDelivered(_ notes: [Note], packets: [PacketNote], messages: [NoteMessage], attachments: [SentAttachment], at date: Date, review: Bool) async {
        guard notes.contains(where: { context(for: $0.documentID)?.isOwner == true }) else { return }
        await enqueue { [self] in
            for original in notes {
                guard let context = context(for: original.documentID), context.isOwner,
                      let packet = packets.first(where: { $0.noteID == original.id }) else { continue }
                do {
                    var note = original; note.body = packet.comment; note.anchor = packet.anchor; note.state = .sent; note.updatedAt = date
                    var turns = messages.filter { $0.noteID == note.id && ownsInput($0.contributorID) }
                    for i in turns.indices {
                        if let body = packet.carriedMessages[turns[i].id] { turns[i].body = body; turns[i].sentAt = date }
                    }
                    let files = attachments.filter { $0.attachment.noteID == note.id }.map { ($0.attachment,$0.data) }
                    var bundle = GlossNoteBundle(note: note, messages: turns, attachments: files, identity: settings.collaborationIdentity,
                                                 isOwner: true, sentAt: date, reviewRequested: review)
                    let remote = context.noteMap.first { $0.value == note.id }?.key ?? note.id
                    bundle.note.id = remote
                    bundle.events.indices.forEach { bundle.events[$0].note = remote }
                    bundle.messages.indices.forEach { bundle.messages[$0].note = remote }
                    let existing = Set(context.snapshot.messages.map(\.id))
                    bundle.messages.removeAll { existing.contains($0.id) }
                    let session = context.session, value = bundle, name = settings.yourName, currentName = context.snapshot.author(settings.authorID)?.name
                    if original.contributorID == nil || original.contributorID == settings.authorID.rawValue {
                        try await Task.detached { try Self.updateName(session,to: name,current: currentName); try Self.publishOwn([value],to: session) }.value
                        try await store.recordReviewPublication([note], messages: [], instance: context.id, identity: settings.collaborationIdentity, at: date)
                    } else {
                        try await Task.detached { try Self.updateName(session,to: name,current: currentName); try session.record(value.events); try session.post(value.messages) }.value
                    }
                    context.snapshot = try await Task.detached { try session.snapshot() }.value
                    context.noteMap = try await store.reviewNoteMap(context.id)
                    context.error = nil
                } catch { context.error = "The notes reached the agent, but the review hasn't synced: \(error.userMessage)" }
            }
        }
    }
}

extension CollaborationModel {
    func retry(_ context: ReviewContext) async {
        await enqueue { [self] in
            do {
                let session = context.session, consolidate = consolidateReviews
                let snapshot = try await Task.detached { try session.startDownloading(); try consolidate(session, true); return try session.snapshot() }.value
                try await adopt(snapshot, into: context)
            } catch { context.error = error.userMessage }
        }
    }
    func updateName() async {
        await enqueue { [self] in
            let name = settings.yourName
            for review in reviews where review.canWrite {
                let currentName = review.snapshot.author(settings.authorID)?.name
                guard currentName != name else { continue }
                let session = review.session
                do {
                    review.snapshot = try await Task.detached { try Self.updateName(session,to: name,current: currentName); return try session.snapshot() }.value
                    review.error = nil
                } catch { review.error = error.userMessage }
            }
        }
    }
    func markContentSeen(_ context: ReviewContext) {
        let id = "content:" + context.snapshot.info.current.hash
        Task { try? await store.markReviewRecordsSeen([id], instance: context.id); context.unread.remove(id) }
    }
}

extension CollaborationModel {
    func relink(_ context: ReviewContext, to documentID: DocumentID) async {
        context.documentID = documentID
        context.error = nil
    }
}

extension CollaborationModel {
    func stop() async {
        stopped = true
        for watcher in watchers.values { watcher.cancel() }
        watchers = [:]; localWatcher?.cancel(); localWatcher = nil
        await operations?.value
        let sessions = reviews.map(\.session)
        await Task.detached { sessions.forEach { $0.close() } }.value
    }
}

extension CollaborationModel {
    private func readStatus(_ session: GlossReviewSession) async -> GlossSyncStatus {
        let reader = statusReader
        return await Task.detached { reader(session) }.value
    }
    func cancelShare() {
        guard !sharingIsActive else { return }
        if shareIsCopy, let url = shareURL {
            let folder = url.deletingLastPathComponent()
            Task.detached { try? FileManager.default.removeItem(at: folder) }
        }
        shareURL = nil; error = nil; needsSave = false
    }
}

extension CollaborationModel {
    func canSendNote(_ note: Note) -> Bool {
        if let review = context(for: note.documentID), !review.isOwner { return isSendable(note) }
        return note.hasUnpublishedChanges || !NotesPanelModel.sendable([note]).isEmpty
    }
}
