import Foundation
import Integrations

/// Files a bug report or a feature request as an issue on Gloss's own repository. This is the app's one write
/// to GitHub, and it only ever goes to this repository; the integrations clients stay GET-only.
///
/// GitHub drops `labels` from anyone without push access, so the body ends with a marker the repository's
/// `label-reports` workflow reads to label every report, whoever sent it.
actor IssueReporter {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case bug
        case feature

        var id: Self { self }
        var label: String { self == .bug ? "bug" : "enhancement" }
        var title: String { self == .bug ? "Bug" : "Feature Request" }
    }

    static let repository = "colinc86/gloss"
    /// GitHub refuses (422) a title over 256 characters or a body over 65,536.
    static let maximumTitle = 256
    static let maximumDescription = 60_000
    nonisolated static let api = URL(string: "https://api.github.com")!

    private let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// Creates the issue and returns its page.
    func create(title: String, body: String, kind: Kind) async throws -> URL {
        var request = URLRequest(url: Self.api.appending(path: "repos/\(Self.repository)/issues"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Gloss", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title, "body": body, "labels": [kind.label]])
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw IntegrationError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw IntegrationError.malformed("not an HTTP response") }
        let message = GetOnlyHTTP.message(in: data) ?? ""
        switch http.statusCode {
        case 200..<300:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let page = (object["html_url"] as? String).flatMap(URL.init(string:)) else {
                throw IntegrationError.malformed("no issue link in the reply")
            }
            return page
        case 401:
            throw IntegrationError.unauthorized(message)
        case 403, 429:
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || http.statusCode == 429
                || message.localizedCaseInsensitiveContains("rate limit") {
                throw IntegrationError.rateLimited(resetAt: nil)
            }
            throw IntegrationError.unauthorized(message.isEmpty ? "Access denied." : message)
        case 404:
            throw IntegrationError.notFound(Self.repository)
        default:
            throw IntegrationError.http(status: http.statusCode, message: message)
        }
    }

    /// Whether a failure means this token can't file here (refused, no access, issues off), so the browser,
    /// signed in as whoever is at the keyboard, is the way to file it. A network hiccup or a rate limit is
    /// worth retrying instead.
    nonisolated static func needsBrowser(_ error: any Error) -> Bool {
        switch error as? IntegrationError {
        case .unauthorized, .notFound: true
        // 422 is GitHub refusing the report itself (too long, say), which the browser form would refuse too.
        case .http(let status, _): status == 410
        default: false
        }
    }

    /// The issue body: what the reader wrote, the versions if they agreed, and the marker for the labeller.
    nonisolated static func body(kind: Kind, description: String, systemInfo: String?) -> String {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [text.isEmpty ? "_No description._" : text]
        if let systemInfo { parts.append("---\n\(systemInfo)") }
        parts.append("<!-- gloss-report: \(kind.rawValue) -->")
        return parts.joined(separator: "\n\n")
    }

    /// "Gloss 0.1.0 (118) · macOS 26.0.1 · arm64": all the report carries about the machine.
    nonisolated static func systemInfo(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return "Gloss \(version) (\(build)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(architecture)"
    }

    /// GitHub's new-issue form, filled in. Browsers and GitHub refuse very long addresses, so the body is cut to
    /// keep the whole address under `limit` characters; the marker and versions at its end survive the cut.
    nonisolated static func browserURL(title: String, description: String, kind: Kind, systemInfo: String?, limit: Int = 7000) -> URL {
        func url(_ text: String) -> URL {
            var components = URLComponents(string: "https://github.com/\(repository)/issues/new")!
            components.queryItems = [
                URLQueryItem(name: "title", value: title),
                URLQueryItem(name: "body", value: body(kind: kind, description: text, systemInfo: systemInfo)),
                URLQueryItem(name: "labels", value: kind.label),
            ]
            // URLComponents leaves `+` and `&`-free text alone; GitHub reads `+` as a space, so encode it.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return components.url!
        }
        var text = description
        var candidate = url(text)
        while candidate.absoluteString.count > limit, !text.isEmpty {
            let excess = candidate.absoluteString.count - limit
            // Encoded characters take up to nine; drop at least enough to close the gap, then measure again.
            text = String(text.dropLast(max(excess / 9, 1) + 1))
            candidate = url(text.isEmpty ? "" : text + "…")
        }
        return candidate
    }
}
