import Foundation

public struct AtlassianUser: Codable, Sendable, Equatable {
    public var accountId: String
    public var displayName: String
    public var emailAddress: String?
}

/// What the Test connection button learns: who the key is, and which of the two products answered.
public struct AtlassianStatus: Sendable, Equatable {
    public var user: AtlassianUser
    public var confluenceReachable: Bool
}

/// Reads Jira issues and Confluence pages from one Atlassian Cloud site with an API token. GET only, like the
/// GitHub client: the app shows the live ticket or page, the agent edits it with its own tools.
public actor AtlassianClient {
    public nonisolated let site: URL
    private let http: GetOnlyHTTP
    private let authorization: String

    /// - site: `https://example.atlassian.net`
    public init(site: URL, email: String, token: String, session: URLSession = .shared, log: @escaping GetOnlyHTTP.Logger = { _ in }) {
        self.site = site
        authorization = "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
        http = GetOnlyHTTP(session: session, log: log)
    }

    /// `example.atlassian.net`, `https://example.atlassian.net/` or `example` all name the same site.
    nonisolated public static func siteURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else { return nil }
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        if !host.contains(".") { components.host = host + ".atlassian.net" }
        return components.url
    }

    private var headers: [String: String] { ["Authorization": authorization, "Accept": "application/json"] }

    private func url(_ path: String, query: [String: String] = [:]) -> URL {
        GetOnlyHTTP.url(site, path: path, query: query)
    }

    private func decode<T: Decodable>(_ type: T.Type, from reply: HTTPReply) throws -> T {
        do { return try JSONDecoder.integrations.decode(type, from: reply.data) } catch { throw IntegrationError.malformed("\(error)") }
    }

    public func myself() async throws -> AtlassianUser {
        try decode(AtlassianUser.self, from: try await http.get(url("rest/api/3/myself"), headers: headers))
    }

    /// Whether Confluence answers on this site (it may be absent, or the token may lack access).
    public func confluenceReachable() async -> Bool {
        (try? await http.get(url("wiki/api/v2/spaces", query: ["limit": "1"]), headers: headers)) != nil
    }

    public func status() async throws -> AtlassianStatus {
        AtlassianStatus(user: try await myself(), confluenceReachable: await confluenceReachable())
    }

    // MARK: Jira

    private static let issueFields = "summary,issuetype,status,priority,assignee,reporter,labels,parent,created,updated,description,comment,project,attachment"

    static func attachments(_ value: Any?) -> [AtlassianAttachment] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = string(entry["id"]), let filename = entry["filename"] as? String else { return nil }
            return AtlassianAttachment(id: id, filename: filename, mimeType: entry["mimeType"] as? String ?? "application/octet-stream", size: entry["size"] as? Int ?? 0)
        }
    }

    /// The link an issue's Markdown uses for an attachment listed as `name`, relative to `KEY.md`.
    nonisolated static func jiraAttachmentLink(key: String, name: String) -> String {
        key + AtlassianPath.jiraAttachmentsSuffix + "/" + name
    }

    private func object(_ reply: HTTPReply) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any] else { throw IntegrationError.malformed("not a JSON object") }
        return object
    }

    private func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let data = Data("\"\(string)\"".utf8)
        return try? JSONDecoder.integrations.decode(Date.self, from: data)
    }

    static func issue(from object: [String: Any]) throws -> JiraIssue {
        guard let key = object["key"] as? String, let id = object["id"] as? String, let fields = object["fields"] as? [String: Any] else {
            throw IntegrationError.malformed("issue without key or fields")
        }
        func name(_ field: String) -> String? { (fields[field] as? [String: Any])?["name"] as? String }
        func display(_ field: String) -> String? { (fields[field] as? [String: Any])?["displayName"] as? String }
        let decoder = JSONDecoder.integrations
        func date(_ field: String) -> Date? {
            guard let string = fields[field] as? String else { return nil }
            return try? decoder.decode(Date.self, from: Data("\"\(string)\"".utf8))
        }
        // Jira's media nodes name Media Services files, not attachments; the file name (alt) is what links them.
        let attachments = Self.attachments(fields["attachment"])
        let listed = AtlassianAttachment.listed(attachments)
        let listedNames = AtlassianAttachment.listedNames(listed)
        let media: ADFMarkdown.MediaLink = { reference in
            let names = [reference.alt, reference.name].compactMap { $0 }
            guard let match = listed.first(where: { names.contains($0.filename) }), let name = listedNames[match.id] else { return nil }
            return (jiraAttachmentLink(key: key, name: name), match.mimeType.hasPrefix("image/"))
        }
        let description = (fields["description"] as? [String: Any]).map { ADFMarkdown.markdown(from: $0, media: media) }
        let comments = ((fields["comment"] as? [String: Any])?["comments"] as? [[String: Any]] ?? []).compactMap { comment -> JiraIssue.Comment? in
            guard let id = comment["id"] as? String else { return nil }
            let body = (comment["body"] as? [String: Any]).map { ADFMarkdown.markdown(from: $0, media: media) } ?? ""
            let created = (comment["created"] as? String).flatMap { try? decoder.decode(Date.self, from: Data("\"\($0)\"".utf8)) } ?? Date(timeIntervalSince1970: 0)
            return JiraIssue.Comment(id: id, author: (comment["author"] as? [String: Any])?["displayName"] as? String ?? "someone", created: created, body: body)
        }
        var issue = JiraIssue(
            key: key, id: id, summary: fields["summary"] as? String ?? "", issueType: name("issuetype") ?? "Issue", status: name("status") ?? "",
            priority: name("priority"), assignee: display("assignee"), reporter: display("reporter"), labels: fields["labels"] as? [String] ?? [],
            parentKey: (fields["parent"] as? [String: Any])?["key"] as? String, created: date("created") ?? Date(timeIntervalSince1970: 0),
            updated: date("updated") ?? Date(timeIntervalSince1970: 0), description: description, comments: comments.sorted { $0.created < $1.created },
            projectKey: (fields["project"] as? [String: Any])?["key"] as? String ?? String(key.split(separator: "-").first ?? "")
        )
        issue.attachments = attachments
        return issue
    }

    /// An issue attachment's bytes, asked for without the redirect to the media host so the request stays on the
    /// site and the key is never sent elsewhere.
    public func jiraAttachment(id: String) async throws -> Data {
        try await http.get(url("rest/api/3/attachment/content/\(id)", query: ["redirect": "false"]), headers: ["Authorization": authorization, "Accept": "*/*"]).data
    }

    public func issue(key: String) async throws -> JiraIssue {
        try Self.issue(from: try object(try await http.get(url("rest/api/3/issue/\(key)", query: ["fields": Self.issueFields]), headers: headers)))
    }

    /// Issues matching a JQL query, newest first, following the new search API's page tokens.
    public func searchIssues(jql: String, limit: Int = 50) async throws -> [JiraIssue.Summary] {
        var results: [JiraIssue.Summary] = []
        var token: String?
        var seen: Set<String> = []
        repeat {
            var query = ["jql": jql, "maxResults": String(min(limit, 100)), "fields": "summary,status,issuetype,project,updated,attachment"]
            if let token { query["nextPageToken"] = token }
            let page = try object(try await http.get(url("rest/api/3/search/jql", query: query), headers: headers))
            for issue in page["issues"] as? [[String: Any]] ?? [] {
                guard let key = issue["key"] as? String, let fields = issue["fields"] as? [String: Any] else { continue }
                results.append(JiraIssue.Summary(
                    key: key, summary: fields["summary"] as? String ?? "", status: (fields["status"] as? [String: Any])?["name"] as? String ?? "",
                    issueType: (fields["issuetype"] as? [String: Any])?["name"] as? String ?? "", projectKey: (fields["project"] as? [String: Any])?["key"] as? String ?? "",
                    updated: date(fields["updated"]) ?? Date(timeIntervalSince1970: 0),
                    viewableAttachments: Self.attachments(fields["attachment"]).filter(\.isViewable).count
                ))
            }
            token = page["isLast"] as? Bool == false ? page["nextPageToken"] as? String : nil
            // A server handing back a token it already gave would loop forever.
            if let next = token, !seen.insert(next).inserted { token = nil }
        } while token != nil && results.count < limit
        return Array(results.prefix(limit))
    }

    nonisolated public func browseURL(forIssue key: String) -> URL { site.appendingPathComponent("browse/\(key)") }

    // MARK: Confluence

    /// Every result of a v2 listing, following `_links.next` (a path under the site) until there is none.
    private func results(startingAt first: URL) async throws -> [[String: Any]] {
        var url = first
        var all: [[String: Any]] = []
        for _ in 0..<40 {
            let page = try object(try await http.get(url, headers: headers))
            all += page["results"] as? [[String: Any]] ?? []
            guard let next = (page["_links"] as? [String: Any])?["next"] as? String, let nextURL = URL(string: next, relativeTo: site)?.absoluteURL, nextURL != url else { break }
            url = nextURL
        }
        return all
    }

    public func spaces() async throws -> [ConfluenceSpace] {
        return try await results(startingAt: url("wiki/api/v2/spaces", query: ["limit": "250", "sort": "name"])).compactMap { value in
            guard let id = Self.string(value["id"]), let key = value["key"] as? String else { return nil }
            return ConfluenceSpace(id: id, key: key, name: value["name"] as? String ?? key, isPersonal: value["type"] as? String == "personal")
        }
    }

    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? Int { return String(number) }
        return nil
    }

    /// A page's attachments. Its media nodes name each one's `fileId`.
    public func pageAttachments(id: String) async throws -> [AtlassianAttachment] {
        try await results(startingAt: url("wiki/api/v2/pages/\(id)/attachments", query: ["limit": "250"])).compactMap { value in
            guard let id = Self.string(value["id"]), let title = value["title"] as? String else { return nil }
            return AtlassianAttachment(id: id, filename: title, mimeType: value["mediaType"] as? String ?? "application/octet-stream",
                                       size: value["fileSize"] as? Int ?? 0, fileID: value["fileId"] as? String, downloadPath: value["downloadLink"] as? String)
        }
    }

    /// A page attachment's bytes from its download link (under the site's `wiki`). Confluence redirects to its media
    /// host, which is followed without the key.
    public func pageAttachment(_ attachment: AtlassianAttachment) async throws -> Data {
        guard let path = attachment.downloadPath, let target = URL(string: "wiki" + (path.hasPrefix("/") ? path : "/" + path), relativeTo: site)?.absoluteURL,
              target.host() == site.host() else { throw IntegrationError.malformed("attachment without a download link on the site") }
        return try await http.get(target, headers: ["Authorization": authorization, "Accept": "*/*"]).data
    }

    func page(from value: [String: Any], body: Bool, media: ADFMarkdown.MediaLink? = nil) -> ConfluencePage? {
        guard let id = Self.string(value["id"]), let title = value["title"] as? String else { return nil }
        let version = value["version"] as? [String: Any]
        var markdown: String?
        if body, let adf = ((value["body"] as? [String: Any])?["atlas_doc_format"] as? [String: Any])?["value"] as? String {
            if let media, let object = try? JSONSerialization.jsonObject(with: Data(adf.utf8)) as? [String: Any] {
                markdown = ADFMarkdown.markdown(from: object, media: media)
            } else {
                markdown = ADFMarkdown.markdown(fromJSON: Data(adf.utf8))
            }
        }
        return ConfluencePage(
            id: id, title: title, spaceId: Self.string(value["spaceId"]) ?? "", parentId: Self.string(value["parentId"]),
            version: version?["number"] as? Int ?? 1, versionDate: date(version?["createdAt"]), authorId: version?["authorId"] as? String,
            webPath: (value["_links"] as? [String: Any])?["webui"] as? String, body: markdown
        )
    }

    /// A space's top-level pages, or a page's children.
    public func pages(inSpace spaceId: String) async throws -> [ConfluencePage] {
        try await results(startingAt: url("wiki/api/v2/spaces/\(spaceId)/pages", query: ["depth": "root", "limit": "250", "sort": "title"])).compactMap { self.page(from: $0, body: false) }
    }

    public func children(ofPage id: String) async throws -> [ConfluencePage] {
        try await results(startingAt: url("wiki/api/v2/pages/\(id)/children", query: ["limit": "250"])).compactMap { self.page(from: $0, body: false) }
    }

    /// Who last changed an issue's fields and when, from its change history (comments are not in it).
    public func lastChange(ofIssue key: String) async throws -> (author: String, at: Date)? {
        let issue = try object(try await http.get(url("rest/api/3/issue/\(key)", query: ["fields": "updated", "expand": "changelog"]), headers: headers))
        let histories = ((issue["changelog"] as? [String: Any])?["histories"] as? [[String: Any]]) ?? []
        return histories.compactMap { history -> (String, Date)? in
            guard let created = date(history["created"]), let author = (history["author"] as? [String: Any])?["displayName"] as? String else { return nil }
            return (author, created)
        }.max { $0.1 < $1.1 }
    }

    /// A Confluence user's display name.
    public func userName(accountId: String) async throws -> String? {
        try object(try await http.get(url("wiki/rest/api/user", query: ["accountId": accountId]), headers: headers))["displayName"] as? String
    }

    /// A page's ancestor pages, the space's top-level page first. Folders and other content types in between are
    /// left out: the tree lists pages only.
    public func ancestors(ofPage id: String) async throws -> [String] {
        try await results(startingAt: url("wiki/api/v2/pages/\(id)/ancestors")).compactMap { value in
            (value["type"] as? String ?? "page") == "page" ? Self.string(value["id"]) : nil
        }
    }

    /// One page with its body as Markdown; `media` places its attached images.
    public func page(id: String, media: ADFMarkdown.MediaLink? = nil) async throws -> ConfluencePage {
        guard let page = page(from: try object(try await http.get(url("wiki/api/v2/pages/\(id)", query: ["body-format": "atlas_doc_format"]), headers: headers)), body: true, media: media) else {
            throw IntegrationError.malformed("page without id or title")
        }
        return page
    }

    nonisolated public func pageURL(_ page: ConfluencePage) -> URL {
        page.webPath.flatMap { URL(string: "wiki" + $0, relativeTo: site)?.absoluteURL } ?? site.appendingPathComponent("wiki/pages/\(page.id)")
    }
}
