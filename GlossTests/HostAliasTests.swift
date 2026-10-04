import Core
import Foundation
import Testing
@testable import Gloss

/// An ssh alias called like an integration host is listed as `<name>-ssh` and still reached by its real alias.
@MainActor
struct HostAliasTests {
    @Test func anAliasNamedLikeAnIntegrationHostKeepsItsAlias() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        let host = try await model.noteStore.upsertHost(name: "github", kind: .ssh)
        // A note keeps the row listed whatever ~/.ssh/config holds on the machine running the test.
        let document = try await model.noteStore.upsertDocument(hostID: host.id, path: "/home/me/a.md", kind: .markdown, fingerprint: Fingerprint())
        _ = try await model.noteStore.createNote(documentID: document.id, anchor: .wholeFile, body: "x", color: .yellow)
        await model.hosts.refresh()
        let entry = try #require(model.hosts.entry(for: host.id))
        #expect(entry.name == "github-ssh")
        #expect(entry.alias == "github", "ssh is given the alias it knows, not the listed name")
        // Herdr names the ssh destination; the follow scope finds the ssh host by it, never the GitHub host.
        #expect(model.hosts.entries.first { $0.kind == .ssh && $0.alias == "github" }?.id == host.id)
        await model.shutDown()
    }
}
