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
    /// The signed-in login, for the empty state, once the token has been checked.
    private(set) var login: String?
    /// Whether a token is saved: without one a pasted URL opens in the browser instead.
    private(set) var hasKey = false
    @ObservationIgnored var onOpen: (PullRequestPath) -> Void = { _ in }
    /// Without a token: the pasted address, to show as a web page.
    @ObservationIgnored var onOpenWeb: (URL) -> Void = { _ in }
    @ObservationIgnored private var all: [GitHubPullRequestSummary] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Shows the panel and lists the user's open pull requests; a nil client means no token is saved. The list
    /// does not wait for the token's check (it searches as whoever the token belongs to).
    func present(client: GitHubClient?, login: String?) {
        self.login = login
        hasKey = client != nil
        query = ""
        selectedIndex = 0
        results = []
        all = []
        errorMessage = nil
        isPresented = true
        loadTask?.cancel()
        guard let client else {
            isLoading = false
            errorMessage = "Save a GitHub token in Settings → Integrations to list and open pull requests. A pasted URL opens in the browser."
            return
        }
        isLoading = true
        loadTask = Task { [weak self] in
            do {
                let pulls = try await client.openPullRequests(limit: 50)
                guard !Task.isCancelled, let self else { return }
                all = pulls
                isLoading = false
                refilter()
            } catch {
                guard !Task.isCancelled, let self else { return }
                isLoading = false
                errorMessage = (error as? IntegrationError)?.message ?? error.userMessage
            }
        }
    }

    /// The reference the query names, when it does.
    var typedReference: PullRequestPath? { PullRequestPath.parse(reference: query) }

    /// What Return does with what is typed: open the pull request, show a pasted URL in the browser (no token), or
    /// nothing (a short reference with no token to open it with).
    enum TypedAction: Equatable { case open(PullRequestPath), browse(URL), needsKey }

    var typedAction: TypedAction? {
        guard let typed = typedReference else { return nil }
        if hasKey { return .open(typed) }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // `github.com/o/r/pull/12` is an address too.
        let address = text.contains("://") ? text : (text.contains("/") && text.contains(".") ? "https://" + text : text)
        if let url = URL(string: address), url.scheme?.hasPrefix("http") == true, url.host() != nil { return .browse(url) }
        return .needsKey
    }

    /// Return: a typed reference opens as is; otherwise the selected pull request. The query stays when nothing
    /// can be opened.
    func submit() {
        switch typedAction {
        case .browse(let url):
            dismiss()
            onOpenWeb(url)
            return
        case .needsKey:
            return
        default:
            break
        }
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
