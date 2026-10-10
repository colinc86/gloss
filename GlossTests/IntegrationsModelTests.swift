import Foundation
import Integrations
import Testing
@testable import Gloss

/// Every request goes to a stub: no test reaches GitHub or an Atlassian site.
@MainActor
struct IntegrationsModelTests {
    static let site = "https://example.atlassian.net"

    func stubbed(github: Stub.Response = .json(#"{"login":"octo"}"#, headers: ["X-OAuth-Scopes": "repo, user"]),
                 myself: Stub.Response = .json(#"{"accountId":"a1","displayName":"Ana Ruiz"}"#)) -> Stub {
        let stub = Stub()
        stub.respond(to: "https://api.github.com/user", with: github)
        stub.respond(to: "\(Self.site)/rest/api/3/myself", with: myself)
        stub.respond(to: "\(Self.site)/wiki/api/v2/spaces?limit=1", with: .json(#"{"results":[]}"#))
        return stub
    }

    @Test func parsesEnvironmentFiles() {
        let text = """
        # keys
        GITHUB_USERNAME=octo
        export GITHUB_ACCESS_TOKEN="ghp_abc"
        ATLASSIAN_USERNAME = ana@example.com
        ATLASSIAN_API_KEY='k=v=w'
        """
        let values = IntegrationsModel.parseEnvironment(text)
        #expect(values == ["GITHUB_USERNAME": "octo", "GITHUB_ACCESS_TOKEN": "ghp_abc", "ATLASSIAN_USERNAME": "ana@example.com", "ATLASSIAN_API_KEY": "k=v=w"])
    }

    @Test func savesAndClearsThroughTheStore() async throws {
        let stub = stubbed()
        let store = MemoryCredentialStore()
        let model = IntegrationsModel(store: store, session: stub.session())
        var changes = 0
        model.onChange = { changes += 1 }
        await model.saveGitHub(token: "  ghp_x  ")
        #expect(model.github?.token == "ghp_x")
        #expect(model.githubStatus == .ok("Signed in as octo · repo, user"))
        #expect(model.githubLogin == "octo")
        #expect(try store.read(account: "github") != nil)
        await model.saveAtlassian(site: "example", email: "c@x.com", token: "tok")
        #expect(model.atlassian?.site == URL(string: Self.site))
        #expect(model.atlassianStatus == .ok("Ana Ruiz · Jira and Confluence"))
        await model.saveAtlassian(site: "nope nope", email: "c@x.com", token: "tok")
        #expect(model.atlassianStatus == .failed("That isn't an Atlassian site. Try example.atlassian.net."))
        model.clear(.github)
        #expect(model.github == nil && model.githubStatus == .unset)
        #expect(try store.read(account: "github") == nil)
        #expect(changes == 3)
        #expect(stub.recorded.allSatisfy { $0.httpMethod == "GET" })

        // A fresh model reads what the store holds, and checks it without holding up whoever called load.
        let again = IntegrationsModel(store: store, session: stub.session())
        await again.load()
        #expect(again.atlassian?.email == "c@x.com")
        #expect(again.github == nil)
        await again.checking?.value
        #expect(again.atlassianStatus == .ok("Ana Ruiz · Jira and Confluence"))
    }

    @Test func aRefusedTokenIsNeverSaved() async throws {
        let stub = stubbed(github: .json(#"{"message":"Bad credentials"}"#, status: 401))
        let store = MemoryCredentialStore()
        let model = IntegrationsModel(store: store, session: stub.session())
        await model.saveGitHub(token: "ghp_typo")
        #expect(model.github == nil)
        #expect(try store.read(account: "github") == nil)
        guard case .failed(let message) = model.githubStatus else { Issue.record("expected a failure"); return }
        #expect(message.hasSuffix("It wasn't saved."), Comment(rawValue: message))
    }

    @Test func aTokenThatCannotBeCheckedIsSavedAndSaysSo() async throws {
        let stub = stubbed(github: .json("{}", status: 503))
        let model = IntegrationsModel(store: MemoryCredentialStore(), session: stub.session())
        await model.saveGitHub(token: "ghp_ok")
        #expect(model.github?.token == "ghp_ok")
        guard case .failed(let message) = model.githubStatus else { Issue.record("expected a failure"); return }
        #expect(message.hasPrefix("Saved; couldn't reach GitHub"), Comment(rawValue: message))
    }

    @Test func aCheckThatFinishesAfterTheKeyWasRemovedIsDropped() async throws {
        let stub = stubbed(github: .json(#"{"login":"octo"}"#, delay: .milliseconds(300)))
        let store = MemoryCredentialStore()
        try store.write(try JSONEncoder().encode(GitHubCredentials(token: "ghp_slow")), account: "github")
        let model = IntegrationsModel(store: store, session: stub.session())
        await model.load()
        #expect(model.github?.token == "ghp_slow", "load returns before the network answers")
        try await Task.sleep(for: .milliseconds(50))
        model.clear(.github)
        await model.checking?.value
        #expect(model.githubStatus == .unset, "the late answer is about a key that is gone")
        #expect(model.githubLogin == nil)
    }

    @Test func savingOneKeyLeavesTheOtherServicesProviderAlone() async throws {
        let stub = stubbed()
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]), integrationsSession: stub.session())
        await model.start()
        await model.integrations.saveGitHub(token: "ghp_x")
        try await waitFor { model.pullRequests != nil }
        let provider = try #require(model.pullRequests)
        await model.integrations.saveAtlassian(site: "example", email: "c@x.com", token: "tok")
        try await waitFor { model.atlassianDocuments != nil }
        #expect(model.pullRequests === provider, "open pull requests keep their provider")
        stub.respond(to: "https://api.github.com/repos/o/r/pulls/2", with: .json("{}", status: 404))
        await model.integrations.saveGitHub(token: "ghp_y")
        try await waitFor { model.integrations.github?.token == "ghp_y" }
        await model.registration?.value
        #expect(model.pullRequests === provider, "a new token goes into the same provider")
        // The provider reads with the new token from here on.
        _ = try? await provider.read("/o/r/pull/2/Pull request.md")
        let read = stub.recorded.last { $0.url?.path == "/repos/o/r/pulls/2" }
        #expect(read != nil, "the provider asked GitHub")
        #expect(read?.value(forHTTPHeaderField: "Authorization")?.hasSuffix("ghp_y") == true, Comment(rawValue: read?.value(forHTTPHeaderField: "Authorization").map { String($0.prefix(7)) } ?? "no header"))
        await model.shutDown()
    }

    @Test func removingAKeyWhileItsCheckRunsWins() async throws {
        let stub = stubbed(github: .json(#"{"login":"octo"}"#, delay: .milliseconds(300)))
        let store = MemoryCredentialStore()
        let model = IntegrationsModel(store: store, session: stub.session())
        async let save: Void = model.saveGitHub(token: "ghp_new")
        try await Task.sleep(for: .milliseconds(50))
        model.clear(.github)
        await save
        #expect(model.github == nil, "the removal came last: the save that finished after it is not written")
        #expect(try store.read(account: "github") == nil)
    }

    func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out")
    }

    /// A site saved with a user and password in it, before the site was cleaned on entry, is read back without them.
    @Test func aSavedSitesUserAndPasswordAreDroppedOnRead() throws {
        let json = #"{"site":"https:\/\/me:secret@Acme.atlassian.net","email":"me@example.com","token":"t"}"#
        let credentials = try JSONDecoder().decode(AtlassianCredentials.self, from: Data(json.utf8))
        #expect(credentials.site == URL(string: "https://acme.atlassian.net"))
        #expect(credentials.email == "me@example.com" && credentials.token == "t")
    }
}
