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
    /// The method is public; the URL (private repositories, file paths, searches) is private outside debug builds.
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
        let read = await Task.detached { () -> (GitHubCredentials?, AtlassianCredentials?, String?) in
            do {
                let github = try store.read(account: Service.github.rawValue).flatMap { try JSONDecoder().decode(GitHubCredentials.self, from: $0) }
                let atlassian = try store.read(account: Service.atlassian.rawValue).flatMap { try JSONDecoder().decode(AtlassianCredentials.self, from: $0) }
                return (github, atlassian, nil)
            } catch {
                return (nil, nil, "Couldn't read the saved keys: \(error)")
            }
        }.value
        github = read.0
        atlassian = read.1
        if let error = read.2 { lastError = error }
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

    /// Saves a token once GitHub has looked at it: a refused token is never stored, so a typo cannot become the
    /// key every pull request then fails with. A network or rate-limit failure still saves it, and says so.
    func saveGitHub(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate = GitHubCredentials(token: trimmed)
        githubStatus = .checking
        do {
            let viewer = try await GitHubClient(token: trimmed, session: session, log: Self.requestLog).viewer()
            guard persist(candidate, as: .github) else { return }
            githubLogin = viewer.login
            githubStatus = .ok(Self.describe(viewer))
        } catch IntegrationError.unauthorized(let detail) {
            githubStatus = .failed((detail.isEmpty ? "GitHub refused the token." : detail) + " It wasn't saved.")
        } catch {
            guard persist(candidate, as: .github) else { return }
            githubStatus = .failed("Saved; couldn't reach GitHub: \(Self.message(error))")
        }
    }

    func saveAtlassian(site: String, email: String, token: String) async {
        guard let url = AtlassianClient.siteURL(from: site) else {
            atlassianStatus = .failed("That isn't an Atlassian site. Try example.atlassian.net.")
            return
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedToken.isEmpty else { return }
        let candidate = AtlassianCredentials(site: url, email: trimmedEmail, token: trimmedToken)
        atlassianStatus = .checking
        do {
            let status = try await AtlassianClient(site: url, email: trimmedEmail, token: trimmedToken, session: session, log: Self.requestLog).status()
            guard persist(candidate, as: .atlassian) else { return }
            atlassianStatus = .ok(Self.describe(status))
        } catch IntegrationError.unauthorized(let detail) {
            atlassianStatus = .failed((detail.isEmpty ? "Atlassian refused the email and token." : detail) + " They weren't saved.")
        } catch {
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
            lastError = "Couldn't save the key: \(error)"
            return false
        }
        onChange()
        return true
    }

    nonisolated static func message(_ error: any Error) -> String {
        (error as? IntegrationError)?.message ?? error.localizedDescription
    }

    nonisolated static func describe(_ viewer: GitHubViewer) -> String {
        "Signed in as \(viewer.login) · " + (viewer.scopes.isEmpty ? "fine-grained token" : viewer.scopes.joined(separator: ", "))
    }

    nonisolated static func describe(_ status: AtlassianStatus) -> String {
        "\(status.user.displayName) · Jira" + (status.confluenceReachable ? " and Confluence" : " (Confluence didn't answer)")
    }

    func clear(_ service: Service) {
        do {
            try store.delete(account: service.rawValue)
        } catch {
            lastError = "Couldn't remove the key: \(error)"
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
        if let token = values["GITHUB_ACCESS_TOKEN"] { await saveGitHub(token: token) }
        if let email = values["ATLASSIAN_USERNAME"], let token = values["ATLASSIAN_API_KEY"],
           let site = atlassianSite ?? values["ATLASSIAN_SITE"] ?? atlassian?.site.absoluteString {
            await saveAtlassian(site: site, email: email, token: token)
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
