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
    nonisolated static let requestLog: GetOnlyHTTP.Logger = { line in IntegrationsModel.log.info("\(line, privacy: .public)") }

    var githubClient: GitHubClient? { github.map { GitHubClient(token: $0.token, session: session, log: Self.requestLog) } }
    var atlassianClient: AtlassianClient? {
        atlassian.map { AtlassianClient(site: $0.site, email: $0.email, token: $0.token, session: session, log: Self.requestLog) }
    }

    func load() async {
        do {
            github = try store.read(account: Service.github.rawValue).flatMap { try JSONDecoder().decode(GitHubCredentials.self, from: $0) }
            atlassian = try store.read(account: Service.atlassian.rawValue).flatMap { try JSONDecoder().decode(AtlassianCredentials.self, from: $0) }
        } catch {
            lastError = "Couldn't read the saved keys: \(error)"
        }
        onChange()
        await test(.github)
        await test(.atlassian)
    }

    func saveGitHub(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await persist(GitHubCredentials(token: trimmed), as: .github)
    }

    func saveAtlassian(site: String, email: String, token: String) async {
        guard let url = AtlassianClient.siteURL(from: site) else {
            atlassianStatus = .failed("That isn't an Atlassian site. Try example.atlassian.net.")
            return
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !trimmedToken.isEmpty else { return }
        await persist(AtlassianCredentials(site: url, email: trimmedEmail, token: trimmedToken), as: .atlassian)
    }

    private func persist(_ value: some Encodable, as service: Service) async {
        do {
            try store.write(try JSONEncoder().encode(value), account: service.rawValue)
            switch service {
            case .github: github = value as? GitHubCredentials
            case .atlassian: atlassian = value as? AtlassianCredentials
            }
            lastError = nil
        } catch {
            lastError = "Couldn't save the key: \(error)"
            return
        }
        onChange()
        await test(service)
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
    func test(_ service: Service) async {
        switch service {
        case .github:
            guard let client = githubClient else { githubStatus = .unset; return }
            githubStatus = .checking
            do {
                let viewer = try await client.viewer()
                githubLogin = viewer.login
                let access = viewer.scopes.isEmpty ? "fine-grained token" : viewer.scopes.joined(separator: ", ")
                githubStatus = .ok("Signed in as \(viewer.login) · \(access)")
            } catch let error as IntegrationError {
                githubStatus = .failed(error.message)
            } catch {
                githubStatus = .failed(error.localizedDescription)
            }
        case .atlassian:
            guard let client = atlassianClient else { atlassianStatus = .unset; return }
            atlassianStatus = .checking
            do {
                let status = try await client.status()
                atlassianStatus = .ok("\(status.user.displayName) · Jira" + (status.confluenceReachable ? " and Confluence" : " (Confluence didn't answer)"))
            } catch let error as IntegrationError {
                atlassianStatus = .failed(error.message)
            } catch {
                atlassianStatus = .failed(error.localizedDescription)
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
