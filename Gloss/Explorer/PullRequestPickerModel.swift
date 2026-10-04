import Core
import Foundation
import Integrations
import Observation

/// Open Pull Request…: the open pull requests the signed-in user is involved in, filtered as the query narrows,
/// or a pasted reference (`https://github.com/o/r/pull/12`, `o/r#12`) opened as is.
@MainActor
@Observable
final class PullRequestPickerModel {
    var isPresented = false
    var query = "" {
        didSet { if query != oldValue { refilter() } }
    }
    private(set) var results: [GitHubPullRequestSummary] = []
    var selectedIndex = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The signed-in login, for the empty state.
    private(set) var login: String?
    @ObservationIgnored var onOpen: (PullRequestPath) -> Void = { _ in }
    @ObservationIgnored private var all: [GitHubPullRequestSummary] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Shows the panel and lists the user's open pull requests; nil arguments mean no token is saved.
    func present(client: GitHubClient?, login: String?) {
        self.login = login
        query = ""
        selectedIndex = 0
        results = []
        all = []
        errorMessage = nil
        isPresented = true
        loadTask?.cancel()
        guard let client, let login else {
            isLoading = false
            errorMessage = "Save a GitHub token in Settings → Integrations to list your pull requests. A pull request URL still opens."
            return
        }
        isLoading = true
        loadTask = Task { [weak self] in
            do {
                let pulls = try await client.openPullRequests(involving: login, limit: 50)
                guard !Task.isCancelled, let self else { return }
                all = pulls
                isLoading = false
                refilter()
            } catch {
                guard !Task.isCancelled, let self else { return }
                isLoading = false
                errorMessage = (error as? IntegrationError)?.message ?? error.localizedDescription
            }
        }
    }

    /// The reference the query names, when it does.
    var typedReference: PullRequestPath? { PullRequestPath.parse(reference: query) }

    /// Return: a typed reference opens as is; otherwise the selected pull request.
    func submit() {
        let chosen: PullRequestPath?
        if let typed = typedReference {
            chosen = typed
        } else if results.indices.contains(selectedIndex) {
            chosen = Self.path(of: results[selectedIndex])
        } else {
            chosen = nil
        }
        guard let chosen else { return }
        dismiss()
        onOpen(chosen)
    }

    func dismiss() {
        isPresented = false
        loadTask?.cancel()
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), results.count - 1)
    }

    nonisolated static func path(of summary: GitHubPullRequestSummary) -> PullRequestPath? {
        let parts = summary.repository.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return PullRequestPath(owner: String(parts[0]), repo: String(parts[1]), number: summary.number)
    }

    /// Every word of the query must appear in `owner/repo #n title`, in any order, case-insensitively.
    nonisolated static func filter(_ pulls: [GitHubPullRequestSummary], query: String) -> [GitHubPullRequestSummary] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return pulls }
        return pulls.filter { pull in
            let haystack = "\(pull.repository) #\(pull.number) \(pull.title)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private func refilter() {
        results = Self.filter(all, query: query)
        selectedIndex = 0
    }
}
