import Foundation
import Testing
@testable import Integrations

struct AtlassianClientTests {
    @Test func siteURLsNormalise() {
        #expect(AtlassianClient.siteURL(from: "example.atlassian.net") == URL(string: "https://example.atlassian.net"))
        #expect(AtlassianClient.siteURL(from: "https://example.atlassian.net/jira/your-work") == URL(string: "https://example.atlassian.net"))
        #expect(AtlassianClient.siteURL(from: "example") == URL(string: "https://example.atlassian.net"))
        #expect(AtlassianClient.siteURL(from: "") == nil)
        #expect(AtlassianClient.siteURL(from: "not a site") == nil)
        #expect(AtlassianClient.siteURL(from: "https://me:secret@Acme.Atlassian.net/jira") == URL(string: "https://acme.atlassian.net"), "no user or password kept, host lowercased")
        #expect(AtlassianClient.siteURL(from: "Acme") == URL(string: "https://acme.atlassian.net"))
    }

    @Test func statusUsesBasicAuthAndOnlyGets() async throws {
        let stub = Stub()
        stub.respond(to: "https://x.atlassian.net/rest/api/3/myself", with: .json(#"{"accountId":"a1","displayName":"Sam Rivera","emailAddress":"c@x.com"}"#))
        stub.respond(to: "https://x.atlassian.net/wiki/api/v2/spaces?limit=1", with: .json(#"{"results":[]}"#))
        let client = AtlassianClient(site: URL(string: "https://x.atlassian.net")!, email: "c@x.com", token: "secret", session: stub.session())
        let status = try await client.status()
        #expect(status.user.displayName == "Sam Rivera" && status.confluenceReachable)
        let auth = stub.recorded.first?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Basic " + Data("c@x.com:secret".utf8).base64EncodedString())
        #expect(Set(stub.recorded.map { $0.httpMethod ?? "" }) == ["GET"])

        stub.respond(to: "https://x.atlassian.net/wiki/api/v2/spaces?limit=1", with: .json(#"{"message":"no"}"#, status: 404))
        #expect(try await client.status().confluenceReachable == false, "a site without Confluence still reports its Jira user")
    }

    @Test(.enabled(if: TestGates.atlassian != nil && TestGates.atlassianSite != nil))
    func liveTokenCanReadItself() async throws {
        let credentials = try #require(TestGates.atlassian)
        let client = AtlassianClient(site: try #require(TestGates.atlassianSite), email: credentials.email, token: credentials.token)
        let status = try await client.status()
        #expect(!status.user.displayName.isEmpty)
    }
}
