import Foundation
import GRDB
import Testing
@testable import Core

struct CollaborationStoreTests {
    let owner = AuthorID.new()
    let morgan = AuthorID.new()
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    func snapshot(copy: Bool = false) -> GlossSnapshot {
        let current = GlossCurrent(hash: Data("saved".utf8).sha256Hex,iteration: 0,capturedAt: start)
        let origin = copy ? GlossOrigin(review: .new(),instance: .new(),iteration: 0,copiedAt: start) : nil
        let info = GlossInfo(id: .new(),instance: .new(),origin: origin,createdAt: start,ownerAuthor: owner,kind: .markdown,title: "README.md",source: .file(name: "README.md",git: nil),current: current)
        return GlossSnapshot(info: info,authors: [GlossAuthor(id: owner,name: "Alex",joinedAt: start),GlossAuthor(id: morgan,name: "Morgan",joinedAt: start)],snapshots: [current.hash])
    }
    func indexed(_ snapshot: GlossSnapshot, store: NoteStore, isOwner: Bool) async throws -> Document {
        let document = try await store.upsertDocument(hostID: isOwner ? .local : .gloss,path: "/\(snapshot.info.instance.rawValue)/README.md",kind: .markdown,fingerprint: Fingerprint())
        try await store.indexReview(snapshot.info,url: URL(fileURLWithPath: "/tmp/Example.gloss"),documentID: document.id,isOwner: isOwner)
        return document
    }
    func note() -> GlossNote { GlossNote(id: .new(),author: morgan,createdAt: start,updatedAt: start,iteration: 0,anchor: .wholeFile,body: "Published",color: .green) }

    @Test func postedIsPrivateFromMCPUntilOwnerDeliveryAndParticipantCannotDeliver() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot(); snapshot.notes = [note()]
        let document = try await indexed(snapshot,store: store,isOwner: true)
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        let local = try #require(try await store.notes(for: document.id).first)
        #expect(local.contributorName == "Morgan" && local.publishedAt != nil && local.state == .draft)
        #expect(try await store.sharedNoteIDs().isEmpty)
        _ = try await store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [local.id],outcome: .delivered,carriedNotes: [local])
        #expect(try await store.sharedNoteIDs().contains(local.id))
        let participantStore = NoteStore(database: try AppDatabase.inMemory())
        let participantDoc = try await indexed(snapshot,store: participantStore,isOwner: false)
        try await participantStore.importReview(snapshot,documentID: participantDoc.id,identity: morgan,isOwner: false)
        let participant = try #require(try await participantStore.notes(for: participantDoc.id).first)
        #expect(try await !participantStore.agentDeliveryAllowed([participant.id]))
        // A receipt after permissions changed is still a delivery; recording must not turn it into a failure.
        _ = try await participantStore.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [participant.id],outcome: .delivered)
        #expect(try await participantStore.sends(for: participant.id).first?.outcome == "delivered")
        #expect(try await participantStore.sharedNoteIDs().isEmpty)
    }
    @Test func answersWaitForExplicitOwnerDeliveryEvenOnPreviouslySentNotes() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot(); let posted = note(); snapshot.notes = [posted]
        snapshot.events = [.sent(posted.id,by: owner,at: start)]
        let document = try await indexed(snapshot,store: store,isOwner: true)
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        let reply = GlossMessage(note: posted.id,author: morgan,kind: .comment,body: "My answer",createdAt: start+5)
        snapshot.messages = [reply]
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        #expect(try await store.messages(for: posted.id).first?.isSent == false)
        let pending = try #require(try await store.note(posted.id))
        #expect(pending.hasUnsentFollowUps)
        _ = try await store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [posted.id],outcome: .delivered,carriedNotes: [pending],carried: [reply.id: reply.body])
        #expect(try await store.messages(for: posted.id).first?.isSent == true)
    }
    @Test func copiesHaveDistinctNotesAndValidLocalMessageIDs() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var live = snapshot(); let shared = note(); live.notes = [shared]
        let question = GlossMessage(note: shared.id,author: owner,via: GlossVia(agent: "Codex"),kind: .question,body: "Which color?",meta: try JSONValue(encoding: ["choices": QuestionChoices(["Blue","Green"],multi: false)]),createdAt: start)
        live.messages = [question]
        var copy = live; copy.info.instance = .new(); copy.info.origin = GlossOrigin(review: live.info.id,instance: live.info.instance,iteration: 0,copiedAt: start)
        let a = try await indexed(live,store: store,isOwner: false), b = try await indexed(copy,store: store,isOwner: false)
        try await store.importReview(live,documentID: a.id,identity: morgan,isOwner: false)
        try await store.importReview(copy,documentID: b.id,identity: morgan,isOwner: false)
        let first = try #require(try await store.notes(for: a.id).first), second = try #require(try await store.notes(for: b.id).first)
        #expect(first.id != second.id)
        #expect(try await store.messages(for: first.id).allSatisfy { MessageID(validating: $0.id.rawValue) != nil })
        #expect(try await store.indexedReviews().count == 2)
    }
    @Test func publicationAndImportPreserveEditsMadeDuringSend() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot()
        let document = try await indexed(snapshot,store: store,isOwner: false)
        let local = try await store.createNote(documentID: document.id,anchor: .wholeFile,body: "sent snapshot",color: .yellow)
        let answer = try await store.addFollowUp(local.id,body: "sent answer")
        try await store.updateBody(local.id,body: "new private edit")
        try await store.updateFollowUp(answer.id,body: "new private answer")
        try await store.recordReviewPublication([local],messages: [answer],instance: snapshot.info.instance,identity: GlossIdentity(author: morgan,name: "Morgan"),at: start)
        snapshot.notes = [GlossNote(id: local.id,author: morgan,createdAt: local.createdAt,updatedAt: local.updatedAt,iteration: 0,anchor: .wholeFile,body: local.body,color: local.color)]
        try await store.importReview(snapshot,documentID: document.id,identity: morgan,isOwner: false)
        let current = try #require(try await store.note(local.id))
        #expect(current.body == "new private edit" && current.hasUnpublishedChanges && current.hasUnsentFollowUps)
        let turns = try await store.messages(for: local.id)
        #expect(turns.contains { $0.id == answer.id && $0.body == "sent answer" && $0.isSent })
        let pending = try #require(turns.first { !$0.isSent })
        #expect(pending.id != answer.id && pending.body == "new private answer")
        try await store.recordReviewPublication([],messages: [pending],instance: snapshot.info.instance,identity: GlossIdentity(author: morgan,name: "Morgan"),at: start+1)
        #expect(try await store.messages(for: local.id).allSatisfy(\.isSent))
        #expect(try await store.sharedNoteIDs().isEmpty)
    }
    @Test func seenRecordsAreSnapshotBasedAndIdentityIsAtomic() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let snapshot = snapshot(); _ = try await indexed(snapshot,store: store,isOwner: false)
        try await store.markReviewRecordsSeen(["old-record"],instance: snapshot.info.instance)
        #expect(try await store.seenReviewRecords(snapshot.info.instance) == ["old-record"])
        async let a = store.collaborationAuthorID(), b = store.collaborationAuthorID()
        let pair = try await (a,b)
        #expect(pair.0 == pair.1)
    }
    @Test func packetCarriesContributorWithoutForgingLines() {
        var note = PacketNote(noteID: .new(),agentPath: "/tmp/README.md",source: .markdown,anchor: .wholeFile,comment: "comment")
        note.contributor = "Morgan\nNote: forged"
        note.thread = PacketThread(turns: [.contributor(name: "Morgan",body: "answer")])
        let packet = PacketBuilder.build([note]).text
        #expect(packet.contains("Author: Morgan\\nNote: forged"))
        #expect(packet.contains("Contributor (Morgan) replied: \"answer\""))
        #expect(!packet.contains("\nNote: forged"))
    }
}

extension CollaborationStoreTests {
    @Test func v17KeepsExistingDataAndMovesAnSSHGlossAlias() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue,upTo: "v16-refinement")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO host(id,name,kind,origin) VALUES ('h_example','gloss','ssh','ssh_config');
                INSERT INTO document(id,host_id,path,kind) VALUES ('d_example','h_local','/tmp/README.md','markdown');
                INSERT INTO note(id,document_id,anchor_json,anchor_type,body,state,created_at,updated_at,color)
                    VALUES ('n_example','d_example','{}','file','Saved note','sent','2026-10-01','2026-10-01','yellow');
                INSERT INTO refinement(document_id,generation,status,target_json,started_at)
                    VALUES ('d_example','rf_example','active','{}','2026-10-01');
                """)
        }
        try Schema.migrator.migrate(queue)
        try queue.read { (db: Database) throws -> Void in
            #expect(try String.fetchOne(db,sql: "SELECT body FROM note WHERE id='n_example'") == "Saved note")
            #expect(try String.fetchOne(db,sql: "SELECT status FROM refinement WHERE document_id='d_example'") == "active")
            #expect(try String.fetchOne(db,sql: "SELECT name FROM host WHERE id='h_example'") == "gloss-ssh")
            #expect(try String.fetchOne(db,sql: "SELECT options_json FROM host WHERE id='h_example'")?.contains("gloss") == true)
            #expect(try Row.fetchAll(db,sql: "PRAGMA foreign_key_check").isEmpty)
        }
        try queue.close()
    }
}

extension CollaborationStoreTests {
    @Test func importedAnswersKeepExistingQuestionLinkAndCannotBeEdited() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot()
        let document = try await indexed(snapshot,store: store,isOwner: true)
        let choices = try QuestionChoices(["Blue","Green"])
        let questionNote = try await store.askUser(documentID: document.id,anchor: .wholeFile,question: "Which color?",author: "Codex",choices: choices)
        let question = try #require(try await store.messages(for: questionNote.id).first)
        snapshot.notes = [GlossNote(id: questionNote.id,author: owner,via: GlossVia(agent: "Codex"),createdAt: questionNote.createdAt,updatedAt: questionNote.updatedAt,iteration: 0,anchor: .wholeFile,body: "",color: .orange)]
        snapshot.messages = [GlossMessage(id: question.id,note: questionNote.id,author: owner,via: GlossVia(agent: "Codex"),kind: .question,body: question.body,meta: .object(["choices": try JSONValue(encoding: choices)]),createdAt: question.createdAt)]
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        let answer = GlossMessage(note: questionNote.id,author: morgan,kind: .comment,body: "Green",inReplyTo: question.id,meta: .object(["selectedOptions": .array([.int(1)])]),createdAt: Date())
        snapshot.messages.append(answer)
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        let imported = try #require(try await store.messages(for: questionNote.id).first { $0.id == answer.id })
        #expect(imported.inReplyTo == question.id && imported.selectedOptions == [1] && !imported.isSent)
        await #expect(throws: NoteStoreError.self) { try await store.updateFollowUp(imported.id,body: "Blue") }
        await #expect(throws: NoteStoreError.self) { try await store.deleteFollowUp(imported.id) }
    }
    @Test func unsentSharedEditsKeepAgentEligibilityAndLastDeliveredBody() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot(); let remote = note(); snapshot.notes = [remote]
        let document = try await indexed(snapshot,store: store,isOwner: true)
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        let note = try #require(try await store.note(remote.id))
        _ = try await store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [note.id],outcome: .delivered,carriedNotes: [note])
        try await store.updateBody(note.id,body: "Private edit")
        #expect(try await store.sharedNoteIDs().contains(note.id))
        #expect(try await store.agentNote(note.id)?.body == "Published")
        try await store.resolveSent(note.id,agent: "Codex")
        #expect(try await store.note(note.id)?.state == .resolved)
        #expect(try await store.note(note.id)?.body == "Private edit")
    }
}

extension CollaborationStoreTests {
    @Test func aBareAgentResolutionHasAStableLaterPublicationTime() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local,path: "/tmp/README.md",kind: .markdown,fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id,anchor: .wholeFile,body: "Fix this",color: .yellow,at: start)
        _ = try await store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [note.id],outcome: .delivered,carriedNotes: [note],at: start+1)
        try await store.resolveSent(note.id,agent: "Codex",at: start+5)
        try await store.updateColor(note.id,color: .green,at: start+10)
        let resolved = try #require(try await store.note(note.id))
        #expect(resolved.resolvedAt == start+5)
        let bundle = GlossNoteBundle(note: resolved,messages: [],attachments: [],identity: GlossIdentity(author: owner,name: "Alex"),isOwner: true,sentAt: start+1,resolvedAt: resolved.resolvedAt)
        let result = GlossFold.fold(bundle.note,messages: bundle.messages,events: bundle.events,info: snapshot().info)
        #expect(result.status == .resolved)
        #expect(result.resolution?.at == start+5)
    }
}

extension CollaborationStoreTests {
    @Test func anOlderSentEchoCannotUndoANewerLocalAgentResolution() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot(); let remote = note(); snapshot.notes = [remote]
        let document = try await indexed(snapshot,store: store,isOwner: true)
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        let local = try #require(try await store.note(remote.id))
        _ = try await store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [local.id],outcome: .delivered,carriedNotes: [local],at: start+1)
        try await store.resolveSent(local.id,agent: "Codex",at: start+1)
        snapshot.events = [.sent(remote.id,by: owner,at: start+1)]
        snapshot.events.append(try .moved(remote.id,by: .new(),to: anchor(20),removed: false,at: start+100))
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        let after = try #require(try await store.note(local.id))
        #expect(after.state == .resolved && after.resolveAgent == "Codex" && after.resolvedAt == start+1)
    }
    @Test func participantsSeeOwnerDeliveryWithoutAcquiringMCPEligibility() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot(); let remote = note(); snapshot.notes = [remote]
        snapshot.events = [.sent(remote.id,by: owner,at: start+1)]
        let document = try await indexed(snapshot,store: store,isOwner: false)
        try await store.importReview(snapshot,documentID: document.id,identity: morgan,isOwner: false)
        #expect(try await store.notes(for: document.id).first?.state == .sent)
        #expect(try await store.sharedNoteIDs().isEmpty)
    }
}

extension CollaborationStoreTests {
    @Test func anOlderResolvedEchoPreservesAPrivateReopenedFollowUp() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot(); let remote = note(); snapshot.notes = [remote]
        let document = try await indexed(snapshot,store: store,isOwner: true)
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        let local = try #require(try await store.note(remote.id))
        _ = try await store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [local.id],outcome: .delivered,carriedNotes: [local],at: start+1)
        try await store.resolveSent(local.id,agent: "Codex",at: start+2)
        _ = try await store.addFollowUp(local.id,body: "Private follow-up",at: start+3)
        snapshot.events = [.sent(remote.id,by: owner,at: start+1),.resolved(remote.id,by: owner,outcome: .done,at: start+2)]
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        let after = try #require(try await store.note(local.id))
        #expect(after.state == .sent && after.resolvedAt == nil && after.hasUnsentFollowUps)
    }
}

extension CollaborationStoreTests {
    @Test func becomingOwnerRestoresReviewFieldsAndKeepsContributorAnswersPending() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot()
        var question = note(); question.author = owner; question.via = GlossVia(agent: "Codex")
        snapshot.notes = [question]
        snapshot.events = [.sent(question.id,by: owner,review: true,at: start),.resolved(question.id,by: owner,outcome: .done,at: start+1),GlossEvent(note: question.id,author: owner,type: .accepted,at: start+2)]
        let answer = GlossMessage(note: question.id,author: morgan,kind: .comment,body: "Published answer",createdAt: start+3)
        let adopted = AuthorID.new()
        let own = GlossMessage(note: question.id,author: adopted,kind: .comment,body: "My posted answer",createdAt: start+3)
        snapshot.messages = [answer,own]
        let document = try await indexed(snapshot,store: store,isOwner: false)
        try await store.importReview(snapshot,documentID: document.id,identity: adopted,isOwner: false)
        let local = try #require(try await store.notes(for: document.id).first)
        #expect(!local.reviewRequested && local.acceptedAt == nil)
        #expect(try await store.messages(for: local.id).first?.isSent == true)
        try await store.reopen(local.id,at: start+4)
        snapshot.info.ownerAuthors = [owner,adopted]
        try await store.indexReview(snapshot.info,url: URL(fileURLWithPath: "/tmp/Example.gloss"),documentID: document.id,isOwner: true)
        try await store.importReview(snapshot,documentID: document.id,identity: adopted,isOwner: true)
        let restored = try #require(try await store.note(local.id))
        #expect(restored.reviewRequested && restored.acceptedAt == start+2)
        let pending = try #require(try await store.messages(for: local.id).first)
        #expect(!pending.isSent)
        #expect(restored.state == .draft)
        let upgradedTurns = try await store.messages(for: local.id)
        #expect(upgradedTurns.first { $0.contributorID == adopted.rawValue }?.isSent == true)
        #expect(upgradedTurns.first { $0.contributorID == morgan.rawValue }?.isSent == false)
        let original = try await store.upsertDocument(hostID: .local,path: "/tmp/README.md",kind: .markdown,fingerprint: Fingerprint())
        try await store.linkReviewOriginal(snapshot.info.instance,to: original.id,baseline: Data("saved".utf8))
        #expect(try await store.sharedNoteIDs().isEmpty)
        _ = try await store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [local.id],outcome: .delivered,carriedNotes: [restored],carried: Dictionary(uniqueKeysWithValues: try await store.messages(for: local.id).map { ($0.id,$0.body) }),at: start+5)
        try await store.importReview(snapshot,documentID: original.id,identity: adopted,isOwner: true)
        #expect(try await store.sharedNoteIDs().contains(local.id))
        #expect(try await store.messages(for: local.id).allSatisfy { $0.isSent })
    }
}

extension CollaborationStoreTests {
    func anchor(_ line: Int) -> Anchor {
        .text(TextAnchor(start: TextPosition(line: line,col: 1),end: TextPosition(line: line,col: 2),text: "x",before: "",after: ""))
    }
    @Test func ownerAnchorsIgnorePackageEchoAndOnlyTakeNewerForeignMoves() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot()
        let document = try await indexed(snapshot,store: store,isOwner: true)
        let local = try await store.createNote(documentID: document.id,anchor: anchor(4),body: "Owner note",color: .green,at: start)
        snapshot.notes = [GlossNote(id: local.id,author: owner,createdAt: start,updatedAt: start,iteration: 0,anchor: anchor(1),body: local.body,color: .green)]
        snapshot.events = [try .moved(local.id,by: owner,to: anchor(2),removed: false,at: start+10)]
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        #expect(try await store.note(local.id)?.anchor == anchor(4))
        try await store.applyRelocation(local.id,to: anchor(5),removed: false,author: nil,at: start+20)
        snapshot.info.ownerAuthors = [owner,morgan]
        snapshot.events.append(try .moved(local.id,by: morgan,to: anchor(3),removed: false,at: start+15))
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        #expect(try await store.note(local.id)?.anchor == anchor(5))
        snapshot.events.append(try .moved(local.id,by: morgan,to: anchor(6),removed: false,at: start+25))
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        #expect(try await store.note(local.id)?.anchor == anchor(6))
        try await store.updateAnchor(local.id,anchor: anchor(7),at: start+26)
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        #expect(try await store.note(local.id)?.anchor == anchor(7))
        // A partial cloud snapshot missing the newest move cannot roll the anchor back to an older one.
        snapshot.events.removeAll { $0.at == start+25 }
        snapshot.events.append(try .moved(local.id,by: morgan,to: anchor(3),removed: false,at: start+22))
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        #expect(try await store.note(local.id)?.anchor == anchor(7))
        let stranger = AuthorID.new()
        let refused = try GlossEvent.moved(local.id,by: stranger,to: anchor(8),removed: false,at: start+30)
        snapshot.events.append(refused)
        #expect(snapshot.folded().first?.refused.contains(refused.id) == true)
        try await store.importReview(snapshot,documentID: document.id,identity: owner,isOwner: true)
        #expect(try await store.note(local.id)?.anchor == anchor(7))
    }
    @Test func anyOwnersTurnsAreAgentSentOnTheSecondMacAndContributorsRemainPending() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot(); let otherOwner = AuthorID.new()
        snapshot.info.ownerAuthors = [owner,otherOwner]
        var shared = note(); shared.author = owner; snapshot.notes = [shared]
        let first = GlossMessage(note: shared.id,author: owner,kind: .comment,body: "First Mac answer",createdAt: start+1)
        let second = GlossMessage(note: shared.id,author: otherOwner,kind: .comment,body: "Second Mac answer",createdAt: start+2)
        let contributor = GlossMessage(note: shared.id,author: morgan,kind: .comment,body: "Still pending",createdAt: start+3)
        snapshot.messages = [first,second,contributor]
        let document = try await indexed(snapshot,store: store,isOwner: true)
        try await store.importReview(snapshot,documentID: document.id,identity: otherOwner,isOwner: true)
        let turns = try await store.messages(for: shared.id)
        #expect(turns.first { $0.id == first.id }?.sentAt == first.createdAt)
        #expect(turns.first { $0.id == second.id }?.sentAt == second.createdAt)
        #expect(turns.first { $0.id == contributor.id }?.isSent == false)
        try await store.database.queue.read { (db: Database) throws -> Void in
            #expect(try Date.fetchOne(db,sql: "SELECT agent_sent_at FROM note_message WHERE id=?",arguments: [first.id.rawValue]) == first.createdAt)
            #expect(try Date.fetchOne(db,sql: "SELECT agent_sent_at FROM note_message WHERE id=?",arguments: [second.id.rawValue]) == second.createdAt)
        }
    }
    @Test func retainedSnapshotsUseHashAndStablePathOnlyForOwnerReviews() async throws {
        let database = try AppDatabase.inMemory(); defer { try? database.close() }
        let store = NoteStore(database: database)
        let snapshot = snapshot(), document = try await indexed(snapshot,store: store,isOwner: true)
        let note = try await store.createNote(documentID: document.id,anchor: .wholeFile,body: "Delivered",color: .yellow)
        let bytes = Data("sent attachment bytes".utf8)
        let attachment = Attachment(id: .new(),noteID: note.id,kind: .crop,localPath: "/tmp/private-mutable-crop.png",width: 10,height: 10)
        _ = try await store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [note.id],outcome: .delivered,carriedNotes: [note],carriedAttachments: [SentAttachment(attachment: attachment,data: bytes)])
        let retained = try #require(try await store.agentResourceAttachments(note.id).first)
        #expect(retained.data == bytes && retained.attachment.localPath != attachment.localPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: retained.attachment.localPath)) == bytes)
        let root = database.retainedAttachmentsURL
        #expect(retained.attachment.localPath.hasPrefix(root.path + "/"))
        let ordinary = try await store.upsertDocument(hostID: .local,path: "/tmp/ordinary.md",kind: .markdown,fingerprint: Fingerprint())
        let privateNote = try await store.createNote(documentID: ordinary.id,anchor: .wholeFile,body: "Unshared",color: .yellow)
        _ = try await store.recordSend(transport: "clipboard",targetJSON: "{}",packetText: "packet",noteIDs: [privateNote.id],outcome: .delivered,carriedNotes: [privateNote],carriedAttachments: [SentAttachment(attachment: attachment,data: bytes)])
        _ = try await store.askUser(documentID: ordinary.id,anchor: .wholeFile,question: "Unshared question",author: "Codex")
        try await database.queue.read { (db: Database) throws -> Void in
            let json = try #require(try String.fetchOne(db,sql: "SELECT attachments_json FROM agent_note_snapshot WHERE note_id=?",arguments: [note.id.rawValue]))
            #expect(json.contains(bytes.sha256Hex) && json.contains(root.path))
            #expect(!json.contains(bytes.base64EncodedString()) && !json.contains("\"data\""))
            #expect(try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM agent_note_snapshot") == 1)
        }
        try bytes.dropFirst().write(to: URL(fileURLWithPath: retained.attachment.localPath))
        #expect(try await store.agentResourceAttachments(note.id).isEmpty)
    }
    @Test func removingAReviewKeepsIdentityMapsAndNotesWhileDroppingSeenRecords() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var snapshot = snapshot(); snapshot.notes = [note()]
        let document = try await indexed(snapshot,store: store,isOwner: false)
        try await store.importReview(snapshot,documentID: document.id,identity: morgan,isOwner: false)
        let ids = try await store.notes(for: document.id).map(\.id)
        try await store.markReviewRecordsSeen(["seen"],instance: snapshot.info.instance)
        try await store.removeReview(snapshot.info.instance)
        #expect(try await store.indexedReviews().isEmpty)
        #expect(try await !store.reviewNoteMap(snapshot.info.instance).isEmpty)
        #expect(try await store.reviewDocumentID(snapshot.info.instance) == document.id)
        #expect(try await store.seenReviewRecords(snapshot.info.instance).isEmpty)
        #expect(try await store.notes(for: document.id).map(\.id) == ids)
    }
}
