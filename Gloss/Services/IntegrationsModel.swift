import Core
import Foundation
import Integrations
import Observation
import OSLog

/// Settings → Integrations: the keys the app reads GitHub and Atlassian with, and what each key turned out to be
/// able to see. The app never writes to either service; the agent does, with its own tools.
@MainActor
@Observable
final class IntegrationsModel {
    enum Status: Equatable {
        case unset
        case checking
        case ok(String)
        case failed(String)
    }

    enum Service: String, CaseIterable { case github, atlassian }

    private(set) var github: GitHubCredentials?
    private(set) var atlassian: AtlassianCredentials?
    private(set) var githubStatus: Status = .unset
    private(set) var atlassianStatus: Status = .unset
    /// What the GitHub token belongs to, once checked; the pull-request picker searches with it.
    private(set) var githubLogin: String?
    var lastError: String?
    /// Something was saved or removed: the app re-registers the hosts these keys serve.
    @ObservationIgnored var onChange: @MainActor () -> Void = {}

    private let store: any CredentialStoring
    private let session: URLSession
    nonisolated private static let log = Logger(subsystem: "com.cnc.Gloss", category: "integrations")

    init(store: any CredentialStoring, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    /// Every request the clients make, with its method, so a live session can be checked for anything but GET
    /// (`log show --info --predicate 'subsystem == "com.cnc.Gloss" AND category == "integrations"'`).
    /// Each line is a method and a URL. Outside debug builds the whole line is private: URLs name private
    /// repositories, file paths and searches. Debug builds show it, so a live session can be checked for GETs.
    nonisolated static let requestLog: GetOnlyHTTP.Logger = { line in
        #if DEBUG
        IntegrationsModel.log.info("\(line, privacy: .public)")
        #else
        IntegrationsModel.log.info("\(line, privacy: .private)")
        #endif
    }

    var githubClient: GitHubClient? { github.map { GitHubClient(token: $0.token, session: session, log: Self.requestLog) } }
    var atlassianClient: AtlassianClient? {
        atlassian.map { AtlassianClient(site: $0.site, email: $0.email, token: $0.token, session: session, log: Self.requestLog) }
    }

    /// Reads the saved keys (off the main thread: the Keychain may be asking whether the app may read them) and
    /// registers what they serve. What each key can see is checked afterwards, without holding up launch.
    func load() async {
        let store = store
        let generations = (github: generation[.github, default: 0], atlassian: generation[.atlassian, default: 0])
        // Each service on its own: one unreadable item does not cost the other its key.
        let read = await Task.detached { () -> (GitHubCredentials?, AtlassianCredentials?, [String]) in
            var errors: [String] = []
            var github: GitHubCredentials?
            var atlassian: AtlassianCredentials?
            do { github = try store.read(account: Service.github.rawValue).flatMap { try JSONDecoder().decode(GitHubCredentials.self, from: $0) } } catch { errors.append("GitHub: \(error.userMessage)") }
            do { atlassian = try store.read(account: Service.atlassian.rawValue).flatMap { try JSONDecoder().decode(AtlassianCredentials.self, from: $0) } } catch { errors.append("Atlassian: \(error.userMessage)") }
            return (github, atlassian, errors)
        }.value
        // A key saved or removed while the Keychain was being read is newer than what the read found.
        if generation[.github, default: 0] == generations.github { github = read.0 }
        if generation[.atlassian, default: 0] == generations.atlassian { atlassian = read.1 }
        if !read.2.isEmpty { lastError = "Couldn't read the saved keys: " + read.2.joined(separator: "; ") }
        onChange()
        checking?.cancel()
        checking = Task { [weak self] in
            async let github: Void? = self?.test(.github)
            async let atlassian: Void? = self?.test(.atlassian)
            _ = await (github, atlassian)
        }
    }

    /// The launch check of both keys, for tests that need to wait for it.
    @ObservationIgnored private(set) var checking: Task<Void, Never>?
    /// Bumped by every save and removal of a service's key: a save whose check finishes after a newer save or a
    /// removal is not written, so the last thing the user did wins.
    @ObservationIgnored private var generation: [Service: Int] = [:]

    private func begin(_ service: Service) -> Int {
        generation[service, default: 0] += 1
        return generation[service, default: 0]
    }

    /// Saves a token once GitHub has looked at it: a refused token is never stored, so a typo cannot become the
    /// key every pull request then fails with. A network or rate-limit failure still saves it, and says so.
    /// - check: false for the debug `--integrations-env` import, which saves without waiting on the network
    ///   (the launch check that follows looks at the key).
    func saveGitHub(token: String, check: Bool = true) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate = GitHubCredentials(token: trimmed)
        let mine = begin(.github)
        guard check else { persist(candidate, as: .github); return }
        let hadKey = github != nil
        githubStatus = .checking
        let result: Result<GitHubViewer, any Error>
        do { result = .success(try await GitHubClient(token: trimmed, session: session, log: Self.requestLog).viewer()) } catch { result = .failure(error) }
        // Saved again or removed meanwhile: that newer action stands.
        guard generation[.github] == mine else { return }
        switch result {
        case .success(let viewer):
            guard persist(candidate, as: .github) else { return }
            githubLogin = viewer.login
            githubStatus = .ok(Self.describe(viewer))
        case .failure(IntegrationError.unauthorized(let detail)):
            let refused = detail.isEmpty ? "GitHub refused the token." : detail
            githubStatus = .failed(refused + (hadKey ? " It wasn't saved; the saved token is still in use." : " It wasn't saved."))
        case .failure(let error):
            guard persist(candidate, as: .github) else { return }
            githubStatus = .failed("Saved; couldn't reach GitHub: \(Self.message(error))")
        }
    }

    func saveAtlassian(site: String, email: String, token: String, check: Bool = true) async {
        guard let url = AtlassianClient.siteURL(from: site) else {
            atlassianStatus = .failed("That isn't an Atlassian site. Try example.atlassian.net.")
            return
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedToken.isEmpty else { return }
        let candidate = AtlassianCredentials(site: url, email: trimmedEmail, token: trimmedToken)
        let mine = begin(.atlassian)
        guard check else { persist(candidate, as: .atlassian); return }
        let hadKey = atlassian != nil
        atlassianStatus = .checking
        let result: Result<AtlassianStatus, any Error>
        do { result = .success(try await AtlassianClient(site: url, email: trimmedEmail, token: trimmedToken, session: session, log: Self.requestLog).status()) } catch { result = .failure(error) }
        guard generation[.atlassian] == mine else { return }
        switch result {
        case .success(let status):
            guard persist(candidate, as: .atlassian) else { return }
            atlassianStatus = .ok(Self.describe(status))
        case .failure(IntegrationError.unauthorized(let detail)):
            let refused = detail.isEmpty ? "Atlassian refused the email and token." : detail
            atlassianStatus = .failed(refused + (hadKey ? " They weren't saved; the saved key is still in use." : " They weren't saved."))
        case .failure(let error):
            guard persist(candidate, as: .atlassian) else { return }
            atlassianStatus = .failed("Saved; couldn't reach \(url.host() ?? "the site"): \(Self.message(error))")
        }
    }

    @discardableResult
    private func persist(_ value: some Encodable, as service: Service) -> Bool {
        do {
            try store.write(try JSONEncoder().encode(value), account: service.rawValue)
            switch service {
            case .github: github = value as? GitHubCredentials
            case .atlassian: atlassian = value as? AtlassianCredentials
            }
            lastError = nil
        } catch {
            lastError = "Couldn't save the key: \(error.userMessage)"
            return false
        }
        onChange()
        return true
    }

    nonisolated static func message(_ error: any Error) -> String {
        (error as? IntegrationError)?.message ?? error.userMessage
    }

    nonisolated static func describe(_ viewer: GitHubViewer) -> String {
        "Signed in as \(viewer.login) · " + (viewer.scopes.isEmpty ? "fine-grained token" : viewer.scopes.joined(separator: ", "))
    }

    nonisolated static func describe(_ status: AtlassianStatus) -> String {
        "\(status.user.displayName) · Jira" + (status.confluenceReachable ? " and Confluence" : " (Confluence didn't answer)")
    }

    func clear(_ service: Service) {
        _ = begin(service)
        do {
            try store.delete(account: service.rawValue)
        } catch {
            lastError = "Couldn't remove the key: \(error.userMessage)"
            return
        }
        switch service {
        case .github:
            github = nil
            githubStatus = .unset
            githubLogin = nil
        case .atlassian:
            atlassian = nil
            atlassianStatus = .unset
        }
        onChange()
    }

    /// Reads what the key can see and says so: the account, and for GitHub the scopes, for Atlassian which of
    /// Jira and Confluence answered.
    /// A result that arrives after the key changed or was removed is dropped: it is about a key that is gone.
    func test(_ service: Service) async {
        switch service {
        case .github:
            guard let client = githubClient, let checked = github else { githubStatus = .unset; return }
            githubStatus = .checking
            let result: Result<GitHubViewer, any Error>
            do { result = .success(try await client.viewer()) } catch { result = .failure(error) }
            guard github == checked else { return }
            switch result {
            case .success(let viewer):
                githubLogin = viewer.login
                githubStatus = .ok(Self.describe(viewer))
            case .failure(let error):
                githubStatus = .failed(Self.message(error))
            }
        case .atlassian:
            guard let client = atlassianClient, let checked = atlassian else { atlassianStatus = .unset; return }
            atlassianStatus = .checking
            let result: Result<AtlassianStatus, any Error>
            do { result = .success(try await client.status()) } catch { result = .failure(error) }
            guard atlassian == checked else { return }
            switch result {
            case .success(let status): atlassianStatus = .ok(Self.describe(status))
            case .failure(let error): atlassianStatus = .failed(Self.message(error))
            }
        }
    }

    // MARK: Development

    /// `--integrations-env <path>`: a KEY=VALUE file (GITHUB_ACCESS_TOKEN, ATLASSIAN_USERNAME, ATLASSIAN_API_KEY,
    /// ATLASSIAN_SITE) loaded into the store, so a scripted run never types a key into a field.
    func importEnvironmentFile(at path: String, atlassianSite: String?) async {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            lastError = "Couldn't read \(path)"
            return
        }
        let values = Self.parseEnvironment(text)
        if let token = values["GITHUB_ACCESS_TOKEN"] { await saveGitHub(token: token, check: false) }
        if let email = values["ATLASSIAN_USERNAME"], let token = values["ATLASSIAN_API_KEY"],
           let site = atlassianSite ?? values["ATLASSIAN_SITE"] ?? atlassian?.site.absoluteString {
            await saveAtlassian(site: site, email: email, token: token, check: false)
        }
    }

    nonisolated static func parseEnvironment(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            var key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") { key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first { value = String(value.dropFirst().dropLast()) }
            values[key] = value
        }
        return values
    }
}
