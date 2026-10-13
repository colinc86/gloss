import Core
import Foundation
import MCP
import Testing
@testable import Transports

struct RefinementMCPTests {
    func fixture() async throws -> (NoteStore, Document, MCPDependencies) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let doc = try await store.upsertDocument(hostID: .local, path: "/tmp/qa.md", kind: .markdown, fingerprint: Fingerprint())
        var deps = MCPServerTests.dependencies(store: store)
        deps.askUser = { q in try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: q.question, author: q.agent, choices: q.choices).id }
        return (store, doc, deps)
    }
    func call(_ name: String, _ args: [String: Value], _ deps: MCPDependencies, host: String = "local") async throws -> CallTool.Result {
        try await MCPServer.callTool(.init(name: name, arguments: args), dependencies: deps, agentHost: host)
    }
    func activate(_ store: NoteStore, _ doc: Document) async throws {
        let r = try await store.beginRefinement(documentID: doc.id, generation: "rf_test", targetJSON: "{}")
        _ = try await store.recordSend(transport: "fake", targetJSON: "{}", packetText: "p", noteIDs: [try #require(r.requestNoteID)], outcome: .delivered, review: true)
    }
    var finishArgs: [String: Value] { ["path": "/tmp/qa.md", "refinement_id": "rf_test", "summary": "Updated examples"] }
    @Test func askUserAcceptsSingleAndMultipleChoices() async throws {
        let (store, doc, deps) = try await fixture()
        for multi in [false, true] {
            #expect(try await call("ask_user", ["path": "/tmp/qa.md", "question": "Q", "choices": [" A ", "B"], "multi": .bool(multi)], deps).isError != true)
        }
        #expect(try await store.notes(for: doc.id).count == 2)
        var modes: Set<Bool> = []
        for note in try await store.notes(for: doc.id) { if let multi = try await store.messages(for: note.id).first?.choices?.multi { modes.insert(multi) } }
        #expect(modes == [false, true])
    }
    @Test func invalidChoicesWriteNothing() async throws {
        let (store, doc, deps) = try await fixture()
        let invalid: [[String: Value]] = [["choices": ["A"]], ["choices": [" A ", "A"]], ["choices": ["", "B"]], ["choices": [1, "B"]], ["choices": "A"], ["multi": true], ["multi": "yes"]]
        for fields in invalid {
            var args: [String: Value] = ["path": "/tmp/qa.md", "question": "Q"]
            args.merge(fields) { _, new in new }
            #expect(try await call("ask_user", args, deps).isError == true)
        }
        #expect(try await store.notes(for: doc.id).isEmpty)
    }
    @Test func replyChoicesRequireAsks() async throws {
        let (store, doc, deps) = try await fixture()
        let q = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Q", author: "agent")
        #expect(try await call("reply_to_note", ["id": .string(q.id.rawValue), "message": "Q2", "choices": ["A", "B"]], deps).isError == true)
        #expect(try await call("reply_to_note", ["id": .string(q.id.rawValue), "message": "Q2", "multi": false], deps).isError == true)
        #expect(try await call("reply_to_note", ["id": .string(q.id.rawValue), "message": "Q2", "asks": true, "choices": ["A", "B"]], deps).isError != true)
        #expect(try await store.messages(for: q.id).last?.choices?.options == ["A", "B"])
    }
    @Test func finishRefinementRequiresTheMatchingDocumentAndGeneration() async throws {
        let (store, doc, deps) = try await fixture()
        try await activate(store, doc)
        let invalid: [[String: Value]] = [["refinement_id": "rf_old"], ["path": "/tmp/missing.md"], ["host": "web"], ["summary": " "], ["summary": .string(String(repeating: "x", count: 501))]]
        for fields in invalid {
            var args = finishArgs; args.merge(fields) { _, new in new }
            #expect(try await call("finish_refinement", args, deps).isError == true)
        }
        #expect(try await store.refinement(for: doc.id)?.status == .active)
        #expect(try await call("finish_refinement", finishArgs, deps).isError != true)
    }
    @Test func finishRefinementRefusesWaitingQuestionsAndUnsentAnswers() async throws {
        let (store, doc, deps) = try await fixture()
        try await activate(store, doc)
        let q = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Q", author: "agent")
        #expect(try await call("finish_refinement", finishArgs, deps).isError == true)
        try await store.addFollowUp(q.id, body: "Answer")
        #expect(try await call("finish_refinement", finishArgs, deps).isError == true)
        _ = try await store.recordSend(transport: "fake", targetJSON: "{}", packetText: "a", noteIDs: [q.id], outcome: .delivered)
        #expect(try await call("finish_refinement", finishArgs, deps).isError != true)
    }
    @Test func finishRefinementAllowsResultsAwaitingReview() async throws {
        let (store, doc, deps) = try await fixture()
        try await activate(store, doc)
        let r = try #require(try await store.refinement(for: doc.id))
        try await store.resolveSent(try #require(r.requestNoteID), message: "Changed it")
        #expect(try await call("finish_refinement", finishArgs, deps).isError != true)
        #expect(try await store.note(try #require(r.requestNoteID))?.awaitsReview == true)
        #expect(try await call("finish_refinement", finishArgs, deps).isError != true)
    }
    @Test func aLateFinishAfterExitDoesNotReactivateRefinement() async throws {
        let (store, doc, deps) = try await fixture()
        try await activate(store, doc)
        try await store.endRefinement(documentID: doc.id)
        #expect(try await call("finish_refinement", finishArgs, deps).isError == true)
        #expect(try await store.refinement(for: doc.id)?.status == .ended)
    }
    @Test func refinementInstructionsDescribeQuestionsChangesAndFinish() {
        #expect(MCPServer.instructions.contains("Apply those answers and make the changes"))
        #expect(MCPServer.instructions.contains("finish_refinement") && MCPServer.instructions.contains("does not accept"))
        #expect(MCPServer.toolSchemas.contains { $0.name == "finish_refinement" })
    }
}

extension RefinementMCPTests {
    @Test func liveWebDocumentsAcceptTheirPacketLocatorForQuestionsAndFinish() async throws {
        let (store, _, original) = try await fixture()
        let web = try await store.upsertDocument(hostID: .web, path: "https://example.test/plan", kind: .web, fingerprint: Fingerprint())
        var deps = original
        deps.askUser = { q in
            #expect(q.path == web.path && q.host == "web")
            return try await store.askUser(documentID: web.id, anchor: .wholeFile, question: q.question, author: q.agent, choices: q.choices).id
        }
        let r = try await store.beginRefinement(documentID: web.id, generation: "rf_web", targetJSON: "{}")
        _ = try await store.recordSend(transport: "fake", targetJSON: "{}", packetText: "request", noteIDs: [r.requestNoteID!], outcome: .delivered)
        #expect(try await call("ask_user", ["path": .string(web.path), "host": "web", "question": "Which?", "choices": ["A", "B"]], deps).isError != true)
        for q in try await store.notes(for: web.id) where q.waitingOnUser { try await store.resolve(q.id) }
        #expect(try await call("finish_refinement", ["path": .string(web.path), "host": "web", "refinement_id": "rf_web", "summary": "Done editing"], deps).isError != true)
    }
}

extension RefinementMCPTests {
    @Test func finishingWithAnEmptyHostUsesTheCallerHostAndNormalizedLocator() async throws {
        let (store, doc, deps) = try await fixture()
        try await activate(store, doc)
        var args = finishArgs
        args["host"] = ""
        args["path"] = "file:///tmp/./qa.md"
        #expect(try await call("finish_refinement", args, deps).isError != true)
        #expect(try await store.refinement(for: doc.id)?.status == .completed)
    }
}
