import Core
import Foundation
import Testing
@testable import Gloss

/// The Add Host form refuses what ssh can't use or the database can't keep, saying why.
struct HostFormTests {
    @Test func namesAndPortsSshCanUse() {
        let taken: Set<String> = ["workbox"]
        #expect(HostForm.problem(name: "buildbox", port: "", taken: taken) == nil)
        #expect(HostForm.problem(name: " buildbox ", port: "2222", taken: taken) == nil, "surrounding spaces are trimmed")
        #expect(HostForm.problem(name: "build box", port: "", taken: taken) == "A name can't contain spaces.")
        #expect(HostForm.problem(name: "-oProxyCommand=x", port: "", taken: taken) == "A name can't start with a hyphen.", "ssh would read it as an option")
        #expect(HostForm.problem(name: "GitHub", port: "", taken: taken) == "“GitHub” is a name Gloss uses for itself.")
        #expect(HostForm.problem(name: "local", port: "", taken: taken) != nil)
        #expect(HostForm.problem(name: "workbox", port: "", taken: taken) == "Another host is already called “workbox”.")
        #expect(HostForm.problem(name: "buildbox", port: "abc", taken: taken) == "The port is a number from 1 to 65535.", "it used to be dropped without a word")
        #expect(HostForm.problem(name: "buildbox", port: "70000", taken: taken) != nil)
        #expect(HostForm.problem(name: "buildbox", port: "", taken: taken, hostName: "10.0.0 .5") == "A host name can't contain spaces.")
        #expect(HostForm.problem(name: "buildbox", port: "", taken: taken, user: "my user") == "A user name can't contain spaces.")
        #expect(HostForm.problem(name: "buildbox", port: "", taken: taken, identityFile: "/k/My Keys/id") == nil, "a space in a path is quoted for ssh")
        #expect(HostForm.problem(name: "buildbox", port: "", taken: taken, identityFile: "/k/\"id") != nil)
        #expect(HostForm.problem(name: "", port: "", taken: taken) == nil, "an empty name only leaves Save off")
    }
}

/// Removing a host warns of every note it deletes, not only those under the folder the notes panel shows.
@MainActor
struct HostRemovalWarningTests {
    @Test func aHostsNotesAreCountedWhereverThePanelIs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-host-notes-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        let host = try await model.noteStore.upsertHost(name: "devbox", kind: .ssh)
        let document = try await model.noteStore.upsertDocument(hostID: host.id, path: "/srv/app/main.py", kind: .code, fingerprint: Fingerprint())
        for body in ["one", "two"] { _ = try await model.noteStore.createNote(documentID: document.id, anchor: .wholeFile, body: body, color: .blue) }
        for _ in 0..<100 where HostsModel.notesOnHost(host.id, in: model.notesPanel.allGroups) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(HostsModel.notesOnHost(host.id, in: model.notesPanel.allGroups) == 2)
        #expect(HostsModel.notesOnHost(host.id, in: model.notesPanel.groups) == 0, "the panel shows this Mac's folder: counting its list missed them")
        await model.shutDown()
    }
}

/// The Dock's "Questions from Agents…" lands on a question even when none is under the folder in front.
@MainActor
struct DockQuestionsTests {
    @Test func aQuestionElsewhereIsOpened() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-dock-questions-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(base)/here", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(base)/there", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try "plan\n".write(toFile: "\(base)/there/plan.md", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", "\(base)/here"]))
        await model.start()
        let document = try await model.noteStore.upsertDocument(hostID: .local, path: "\(base)/there/plan.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await model.noteStore.createNote(documentID: document.id, anchor: .wholeFile, body: "", color: .orange)
        _ = try await model.noteStore.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "", noteIDs: [note.id], outcome: .delivered)
        try await model.noteStore.agentReply(note.id, body: "Which cache?", asks: true, agent: "claude")
        for _ in 0..<100 where !model.notesPanel.allGroups.contains(where: { $0.notes.contains(where: \.waitingOnUser) }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.notesPanel.groups.contains { $0.notes.contains(where: \.waitingOnUser) }, "nothing waiting under the folder in front")

        model.showQuestionsFromAgents()
        for _ in 0..<150 where model.activeSession?.path != "\(base)/there/plan.md" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.activeSession?.path == "\(base)/there/plan.md", "the question's document opens")
        #expect(model.notesPanel.filter == .attention && model.showNotesPanel)
        await model.shutDown()
    }
}
