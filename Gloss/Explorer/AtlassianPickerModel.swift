import Core
import Foundation
import Integrations
import Observation

/// Open Jira Issue or Confluence Page…: an issue key or a URL opens as is; otherwise the issues the user is part
/// of (Jira) or the site's spaces (Confluence), narrowed as the query grows.
@MainActor
@Observable
final class AtlassianPickerModel {
    enum Product: String, CaseIterable, Identifiable {
        case jira, confluence
        var id: String { rawValue }
        var title: String { self == .jira ? "Jira" : "Confluence" }
    }

    struct Row: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String
        var reference: AtlassianPath
    }

    var isPresented = false
    var product: Product = .jira {
        didSet { if product != oldValue { refilter() } }
    }
    var query = "" {
        didSet { if query != oldValue { refilter() } }
    }
    private(set) var results: [Row] = []
    var selectedIndex = 0
    private(set) var isLoading = false
    /// Why the shown product's list is empty: no key saved, or that product's own refusal.
    var errorMessage: String? { noKeyMessage ?? (product == .jira ? jiraError : confluenceError) }
    private var noKeyMessage: String?
    private var jiraError: String?
    private var confluenceError: String?
    private(set) var site: URL?
    @ObservationIgnored var onOpen: (AtlassianPath) -> Void = { _ in }
    @ObservationIgnored private var issues: [Row] = []
    @ObservationIgnored private var spaces: [Row] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func present(client: AtlassianClient?, product: Product? = nil) {
        if let product { self.product = product }
        site = client?.site
        query = ""
        selectedIndex = 0
        results = []
        issues = []
        spaces = []
        noKeyMessage = nil
        jiraError = nil
        confluenceError = nil
        isPresented = true
        loadTask?.cancel()
        guard let client else {
            isLoading = false
            noKeyMessage = "Save your Atlassian site, email and API token in Settings → Integrations to list issues and spaces. An issue key or a URL still opens."
            return
        }
        isLoading = true
        loadTask = Task { [weak self] in
            async let issues = client.searchIssues(jql: "assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser() ORDER BY updated DESC", limit: 50)
            async let spaces = client.spaces()
            var issueRows: [Row] = [], spaceRows: [Row] = []
            var jiraError: String?, confluenceError: String?
            do {
                issueRows = try await issues.map { Row(id: $0.key, title: $0.summary, detail: "\($0.key) · \($0.issueType) · \($0.status) · updated \($0.updated.formatted(.relative(presentation: .named)))", reference: .jiraIssue(project: $0.projectKey, key: $0.key)) }
            } catch {
                jiraError = Self.explain("Jira", error)
            }
            do {
                // Team spaces first, people's own spaces after; the API sorts by name within each.
                let all = try await spaces
                spaceRows = (all.filter { !$0.isPersonal } + all.filter(\.isPersonal))
                    .map { Row(id: $0.id, title: $0.name, detail: $0.isPersonal ? "\($0.key) · personal" : $0.key, reference: .confluenceSpace($0.key)) }
            } catch {
                confluenceError = Self.explain("Confluence", error)
            }
            guard !Task.isCancelled, let self else { return }
            self.issues = issueRows
            self.spaces = spaceRows
            self.jiraError = jiraError
            self.confluenceError = confluenceError
            isLoading = false
            refilter()
        }
    }

    nonisolated static func explain(_ product: String, _ error: any Error) -> String {
        let reason = (error as? IntegrationError)?.message ?? error.localizedDescription
        return "\(product) didn't answer: \(reason). Check the key in Settings → Integrations; an issue key or a URL still opens."
    }

    var typedReference: AtlassianPath? { AtlassianPath.parse(reference: query, site: site) }

    func submit() {
        let chosen: AtlassianPath?
        if let typed = typedReference {
            chosen = typed
        } else if results.indices.contains(selectedIndex) {
            chosen = results[selectedIndex].reference
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

    nonisolated static func filter(_ rows: [Row], query: String) -> [Row] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            let haystack = "\(row.title) \(row.detail)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private func refilter() {
        results = Self.filter(product == .jira ? issues : spaces, query: query)
        selectedIndex = 0
    }
}
