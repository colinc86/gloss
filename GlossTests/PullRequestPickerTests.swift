import Core
import Foundation
import Integrations
import Testing
@testable import Gloss

@MainActor
struct PullRequestPickerTests {
    func summary(_ repo: String, _ number: Int, _ title: String, draft: Bool = false) -> GitHubPullRequestSummary {
        GitHubPullRequestSummary(number: number, title: title, state: "open", draft: draft, htmlUrl: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
                                 updatedAt: Date(timeIntervalSince1970: 1_700_000_000), repositoryUrl: URL(string: "https://api.github.com/repos/\(repo)")!)
    }

    @Test func filtersByEveryWordAcrossRepoNumberAndTitle() {
        let pulls = [summary("acme/widget-api", 2, "Name job consumer"), summary("acme/billing-api", 50, "Cache user lookups"), summary("colinc86/notes", 7, "Draft: job fan-out", draft: true)]
        #expect(PullRequestPickerModel.filter(pulls, query: "").count == 3)
        #expect(PullRequestPickerModel.filter(pulls, query: "job").map(\.number) == [2, 7])
        #expect(PullRequestPickerModel.filter(pulls, query: "Job widget").map(\.number) == [2])
        #expect(PullRequestPickerModel.filter(pulls, query: "#50").map(\.number) == [50])
        #expect(PullRequestPickerModel.filter(pulls, query: "nothing here").isEmpty)
        #expect(PullRequestPickerModel.path(of: pulls[0]) == PullRequestPath(owner: "acme", repo: "widget-api", number: 2))
    }

    @Test func aTypedReferenceOpensAsIs() {
        let picker = PullRequestPickerModel()
        var opened: PullRequestPath?
        picker.onOpen = { opened = $0 }
        picker.present(client: nil, login: nil)
        #expect(picker.errorMessage?.contains("Settings → Integrations") == true, "no token: the list cannot load, a URL still opens")
        picker.query = "https://github.com/o/r/pull/12/files/Sources/A.swift"
        #expect(picker.typedReference?.changedFile == "Sources/A.swift")
        picker.submit()
        #expect(opened?.path == "/o/r/pull/12/changes/Sources/A.swift")
        #expect(!picker.isPresented)
    }

    @Test func resourceURLsResolveToTheGitHubHost() {
        #expect(AppModel.resolveResourceURL(URL(string: "https://github.com/o/r/pull/12")!)?.path == "/o/r/pull/12/Pull request.md")
        #expect(AppModel.resolveResourceURL(URL(string: "https://github.com/o/r/pull/12/files/a/b.swift")!)?.path == "/o/r/pull/12/changes/a/b.swift")
        #expect(AppModel.resolveResourceURL(URL(string: "https://github.com/o/r/pull/12")!)?.host == "github")
        #expect(AppModel.resolveResourceURL(URL(string: "https://example.com/")!) == nil)
        let hosts: [String: HostID] = [:]
        #expect(URLRouter.parse(URL(string: "gloss://open?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F12")!, hosts: hosts) == .open(hostID: .github, path: "/o/r/pull/12/Pull request.md", line: nil))
        #expect(URLRouter.parse(URL(string: "gloss://open?url=https%3A%2F%2Fexample.com%2Fdocs")!, hosts: hosts) == .open(hostID: .local, path: "https://example.com/docs", line: nil))
        #expect(URLRouter.parse(URL(string: "gloss://open?url=ftp%3A%2F%2Fx")!, hosts: hosts) == nil)
    }
}
