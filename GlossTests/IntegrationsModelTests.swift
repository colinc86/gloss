import Foundation
import Testing
@testable import Gloss

@MainActor
struct IntegrationsModelTests {
    @Test func parsesEnvironmentFiles() {
        let text = """
        # keys
        GITHUB_USERNAME=colinc86
        export GITHUB_ACCESS_TOKEN="ghp_abc"
        ATLASSIAN_USERNAME = colin@example.com
        ATLASSIAN_API_KEY='k=v=w'
        """
        let values = IntegrationsModel.parseEnvironment(text)
        #expect(values == ["GITHUB_USERNAME": "colinc86", "GITHUB_ACCESS_TOKEN": "ghp_abc", "ATLASSIAN_USERNAME": "colin@example.com", "ATLASSIAN_API_KEY": "k=v=w"])
    }

    @Test func savesAndClearsThroughTheStore() async throws {
        let store = MemoryCredentialStore()
        let model = IntegrationsModel(store: store)
        var changes = 0
        model.onChange = { changes += 1 }
        await model.saveGitHub(token: "  ghp_x  ")
        #expect(model.github?.token == "ghp_x")
        #expect(try store.read(account: "github") != nil)
        await model.saveAtlassian(site: "example", email: "c@x.com", token: "tok")
        #expect(model.atlassian?.site == URL(string: "https://example.atlassian.net"))
        await model.saveAtlassian(site: "nope nope", email: "c@x.com", token: "tok")
        #expect(model.atlassianStatus == .failed("That isn't an Atlassian site. Try example.atlassian.net."))
        model.clear(.github)
        #expect(model.github == nil && model.githubStatus == .unset)
        #expect(try store.read(account: "github") == nil)
        #expect(changes == 3)

        // A fresh model reads what the store holds.
        let again = IntegrationsModel(store: store)
        await again.load()
        #expect(again.atlassian?.email == "c@x.com")
        #expect(again.github == nil)
    }
}
