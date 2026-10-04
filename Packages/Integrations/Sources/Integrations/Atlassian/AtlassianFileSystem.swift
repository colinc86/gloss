import Core
import Foundation

/// Jira issues and Confluence pages as a small read-only tree on the `atlassian` host: `/jira/<PROJECT>/<KEY>.md`
/// (the issues the user is part of, listed by project) and `/confluence/<SPACE>/<page id>/<Title>.md` (a space's
/// pages, each page's folder holding the page and its children). Read with the user's token; never written.
public actor AtlassianFileSystem: FileSystemProvider {
    public nonisolated let hostID = HostID.atlassian
    private var client: AtlassianClient
    private let pollInterval: Duration

    struct IssueDocument {
        var issue: JiraIssue
        var data: Data
        var description: ClosedRange<Int>
        var comments: [(range: ClosedRange<Int>, id: String)]
        var fetchedAt: ContinuousClock.Instant = .now
    }

    struct PageDocument {
        var page: ConfluencePage
        var spaceKey: String
        var data: Data
        var fetchedAt: ContinuousClock.Instant = .now
    }

    private final class Poller {
        var task: Task<Void, Never>?
        var continuations: [UUID: AsyncStream<FileSystemEvent>.Continuation] = [:]
    }

    private var issues: [String: IssueDocument] = [:]
    /// Listings live briefly: a root re-listed after this long asks Jira or Confluence again, so a newly assigned
    /// issue or a new space shows up without re-saving the key.
    private let listingLifetime: Duration = .seconds(30)
    private var issueLists: [String: (list: [JiraIssue.Summary], fetchedAt: ContinuousClock.Instant)] = [:]
    private var spaces: (list: [ConfluenceSpace], fetchedAt: ContinuousClock.Instant)?
    private var pages: [String: PageDocument] = [:]
    /// Titles and versions seen in listings, so a folder names its own document without fetching the body.
    private var pageTitles: [String: ConfluencePage] = [:]
    private var pollers: [String: Poller] = [:]

    /// A new key for the same site. Open documents and pollers carry on with it; the documents they compare
    /// against stay, so the next poll still reports a change made meanwhile. Listings read with the old key are
    /// dropped.
    public func replaceClient(_ client: AtlassianClient) {
        self.client = client
        issueLists = [:]
        spaces = nil
        pageTitles = [:]
    }
    private var terminated: Set<UUID> = []

    public init(client: AtlassianClient, pollInterval: Duration = .seconds(10)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    nonisolated static func fileSystemError(_ error: any Error, path: String) -> any Error {
        guard let error = error as? IntegrationError else { return error }
        switch error {
        case .notFound: return FileSystemError.notFound(path)
        case .unauthorized(let message): return FileSystemError.permissionDenied(message.isEmpty ? path : message)
        default: return FileSystemError.io(error.message)
        }
    }

    private func parse(_ path: String) throws -> AtlassianPath {
        guard let parsed = AtlassianPath(path) else { throw FileSystemError.notFound(path) }
        return parsed
    }

    /// A document read a while ago is read again when it is next asked for, unless a watcher keeps it fresh: a
    /// reopened ticket shows today's text, not the first read's followed by an "updated" banner.
    private func isFresh(_ fetchedAt: ContinuousClock.Instant, _ path: AtlassianPath?) -> Bool {
        if let path, pollers[path.path] != nil { return true }
        return ContinuousClock.now - fetchedAt < listingLifetime
    }

    // MARK: Jira

    private func issueDocument(_ key: String, project: String, refresh: Bool = false) async throws -> IssueDocument {
        if !refresh, let cached = issues[key], isFresh(cached.fetchedAt, AtlassianPath.jiraIssue(project: project, key: key)) { return cached }
        do {
            let issue: JiraIssue
            do { issue = try await client.issue(key: key) } catch {
                // Offline or refused on a re-read: the copy already shown is better than an error.
                if !refresh, let cached = issues[key] { return cached }
                throw error
            }
            let rendered = AtlassianMarkdown.issue(issue, url: client.browseURL(forIssue: key))
            let document = IssueDocument(issue: issue, data: Data(rendered.text.utf8), description: rendered.description, comments: rendered.comments)
            issues[key] = document
            return document
        } catch {
            throw Self.fileSystemError(error, path: AtlassianPath.jiraIssue(project: project, key: key).path)
        }
    }

    /// The issues the user is part of in a project, most recently updated first.
    private func issueList(_ project: String) async throws -> [JiraIssue.Summary] {
        if let cached = issueLists[project], ContinuousClock.now - cached.fetchedAt < listingLifetime { return cached.list }
        do {
            // The 200 most recently updated: a project root is for the issues one works on, not the whole backlog.
            let list = try await client.searchIssues(jql: "project = \"\(project)\" AND (assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser()) ORDER BY updated DESC", limit: 200)
            issueLists[project] = (list, .now)
            return list
        } catch {
            throw Self.fileSystemError(error, path: AtlassianPath.jiraProject(project).path)
        }
    }

    // MARK: Confluence

    private func space(_ key: String) async throws -> ConfluenceSpace {
        let known = spaces.flatMap { ContinuousClock.now - $0.fetchedAt < listingLifetime ? $0.list : nil }
        let list: [ConfluenceSpace]
        if let known {
            list = known
        } else {
            do { list = try await client.spaces() } catch { throw Self.fileSystemError(error, path: AtlassianPath.confluenceSpace(key).path) }
            spaces = (list, .now)
        }
        guard let space = list.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else { throw FileSystemError.notFound(AtlassianPath.confluenceSpace(key).path) }
        return space
    }

    private func pageDocument(_ id: String, space: String, refresh: Bool = false) async throws -> PageDocument {
        if !refresh, let cached = pages[id], isFresh(cached.fetchedAt, nil) || pollers.keys.contains(where: { AtlassianPath($0)?.pageID == id }) { return cached }
        do {
            let page: ConfluencePage
            do { page = try await client.page(id: id) } catch {
                if !refresh, let cached = pages[id] { return cached }
                throw error
            }
            pageTitles[id] = page
            let document = PageDocument(page: page, spaceKey: space, data: Data(AtlassianMarkdown.page(page, spaceKey: space, url: client.pageURL(page)).utf8))
            pages[id] = document
            return document
        } catch {
            throw Self.fileSystemError(error, path: AtlassianPath.confluencePageFolder(space: space, id: id).path)
        }
    }

    /// Page folders, named by title; their paths nest under `parent`'s, so the tree's paths follow its nesting.
    private func entries(for pages: [ConfluencePage], space: String, under parent: AtlassianPath?) -> [DirectoryEntry] {
        pages.map { page in
            pageTitles[page.id] = page
            let folder = parent?.childFolder(page.id) ?? .confluencePageFolder(space: space, id: page.id)
            return DirectoryEntry(name: AtlassianPath.fileTitle(page.title), path: folder.path, kind: .directory, mtime: page.versionDate, mode: 0o555)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: FileSystemProvider

    public func list(_ directory: String) async throws -> [DirectoryEntry] {
        switch try parse(directory) {
        case .jiraRoot, .confluenceRoot:
            // Roots are chosen in the picker; neither products' top level is browsed.
            return []
        case .jiraProject(let project):
            return try await issueList(project).map { issue in
                DirectoryEntry(name: "\(issue.key).md", path: AtlassianPath.jiraIssue(project: project, key: issue.key).path, kind: .file, mtime: issue.updated, mode: 0o444)
            }
        case .confluenceSpace(let key):
            let space = try await space(key)
            do { return entries(for: try await client.pages(inSpace: space.id), space: key, under: nil) } catch { throw Self.fileSystemError(error, path: directory) }
        case .confluencePageFolder(let space, let id, let ancestors):
            // The folder's own document is named from what a listing already said about the page, so expanding a
            // folder fetches its children only; the body comes when the document opens.
            let own: (title: String, size: Int64?, mtime: Date?)
            if let document = pages[id] {
                own = (document.page.title, Int64(document.data.count), document.page.versionDate)
            } else if let page = pageTitles[id] {
                own = (page.title, nil, page.versionDate)
            } else {
                let document = try await pageDocument(id, space: space)
                own = (document.page.title, Int64(document.data.count), document.page.versionDate)
            }
            let title = AtlassianPath.fileTitle(own.title)
            var entries = [DirectoryEntry(name: title + ".md", path: AtlassianPath.confluencePage(space: space, id: id, title: title, ancestors: ancestors).path, kind: .file, size: own.size, mtime: own.mtime, mode: 0o444)]
            let folder = AtlassianPath.confluencePageFolder(space: space, id: id, ancestors: ancestors)
            do { entries += self.entries(for: try await client.children(ofPage: id), space: space, under: folder) } catch { throw Self.fileSystemError(error, path: directory) }
            return entries
        case .jiraIssue, .confluencePage:
            throw FileSystemError.notADirectory(directory)
        }
    }

    public func stat(_ path: String) async throws -> FileAttributes {
        switch try parse(path) {
        case .jiraRoot, .confluenceRoot:
            return FileAttributes(kind: .directory, size: 0, mtime: Date(timeIntervalSince1970: 0), mode: 0o555)
        case .jiraProject(let project):
            // Ask Jira before the explorer records the root, so a mistyped project never becomes a tab.
            _ = try await issueList(project)
            return FileAttributes(kind: .directory, size: 0, mtime: Date(timeIntervalSince1970: 0), mode: 0o555)
        case .confluenceSpace(let key):
            _ = try await space(key)
            return FileAttributes(kind: .directory, size: 0, mtime: Date(timeIntervalSince1970: 0), mode: 0o555)
        case .jiraIssue(let project, let key):
            let document = try await issueDocument(key, project: project)
            return FileAttributes(kind: .file, size: Int64(document.data.count), mtime: document.issue.updated, mode: 0o444)
        case .confluencePageFolder(let space, let id, _):
            let document = try await pageDocument(id, space: space)
            return FileAttributes(kind: .directory, size: 0, mtime: document.page.versionDate ?? Date(timeIntervalSince1970: 0), mode: 0o555)
        case .confluencePage(let space, let id, _, _):
            // The title in the path is cosmetic: a renamed page keeps its document and its notes.
            let document = try await pageDocument(id, space: space)
            return FileAttributes(kind: .file, size: Int64(document.data.count), mtime: document.page.versionDate ?? Date(timeIntervalSince1970: 0), mode: 0o444)
        }
    }

    public func read(_ path: String) async throws -> Data {
        switch try parse(path) {
        case .jiraIssue(let project, let key):
            return try await issueDocument(key, project: project).data
        case .confluencePage(let space, let id, _, _):
            return try await pageDocument(id, space: space).data
        default:
            throw FileSystemError.notFound(path)
        }
    }

    public func writeAtomically(_ data: Data, to path: String, preservingModeFrom original: FileAttributes?) async throws -> FileAttributes { throw FileSystemError.permissionDenied(path) }
    public func makeDirectory(_ path: String) async throws { throw FileSystemError.permissionDenied(path) }
    public func rename(_ path: String, to newPath: String) async throws { throw FileSystemError.permissionDenied(path) }
    public func delete(_ path: String) async throws { throw FileSystemError.permissionDenied(path) }

    /// Polls an issue's update time or a page's version while anyone watches it; a change refreshes the document
    /// and reports its path. Roots and folders are not polled.
    public nonisolated func watch(_ path: String) -> AsyncStream<FileSystemEvent> {
        guard let parsed = AtlassianPath(path) else { return AsyncStream { $0.finish() } }
        switch parsed {
        case .jiraIssue, .confluencePage: break
        default: return AsyncStream { $0.finish() }
        }
        let id = UUID()
        return AsyncStream { continuation in
            Task { await self.addWatcher(id, continuation: continuation, path: parsed) }
            continuation.onTermination = { _ in Task { await self.removeWatcher(id, path: parsed) } }
        }
    }

    private func addWatcher(_ id: UUID, continuation: AsyncStream<FileSystemEvent>.Continuation, path: AtlassianPath) {
        if terminated.remove(id) != nil {
            continuation.finish()
            return
        }
        let poller = pollers[path.path] ?? Poller()
        poller.continuations[id] = continuation
        pollers[path.path] = poller
        if poller.task == nil {
            poller.task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.pollInterval ?? .seconds(10))
                    guard !Task.isCancelled, let self else { return }
                    await self.poll(path)
                }
            }
        }
    }

    private func removeWatcher(_ id: UUID, path: AtlassianPath) {
        guard let poller = pollers[path.path], poller.continuations[id] != nil else {
            terminated.insert(id)
            return
        }
        poller.continuations[id] = nil
        if poller.continuations.isEmpty {
            poller.task?.cancel()
            pollers[path.path] = nil
        }
    }

    private func poll(_ path: AtlassianPath) async {
        var changed = false
        switch path {
        case .jiraIssue(let project, let key):
            guard let previous = issues[key], let fresh = try? await issueDocument(key, project: project, refresh: true) else { return }
            changed = fresh.issue.updated != previous.issue.updated || fresh.data != previous.data
        case .confluencePage(let space, let id, _, _):
            guard let previous = pages[id], let fresh = try? await pageDocument(id, space: space, refresh: true) else { return }
            changed = fresh.page.version != previous.page.version
        default:
            return
        }
        guard changed, let poller = pollers[path.path] else { return }
        for continuation in poller.continuations.values { continuation.yield(.changed([path.path])) }
    }

    // MARK: What the app asks beyond files

    /// For the packet: the issue's or page's URL and what in it the document is.
    public func resource(for path: String, line: Int? = nil) async -> PacketResource? {
        switch AtlassianPath(path) {
        case .jiraIssue(let project, let key)?:
            guard let document = try? await issueDocument(key, project: project) else { return PacketResource(url: client.browseURL(forIssue: key)) }
            if let line, let comment = document.comments.first(where: { $0.range.contains(line) }) {
                // Jira's deep link to one comment, so the agent (and a click) lands on it.
                return PacketResource(url: client.browseURL(forIssue: key), details: ["Comment: \(client.browseURL(forIssue: key).absoluteString)?focusedCommentId=\(comment.id)"])
            }
            // The field the line is in: the title is the summary, the Description section the description; the
            // fact lines, the headings and a whole-file note are about the issue as a whole.
            let updated = "Updated: \(AtlassianMarkdown.stamp(document.issue.updated))"
            switch line {
            case 1?: return PacketResource(url: client.browseURL(forIssue: key), details: ["Field: summary", updated])
            case let line? where document.description.contains(line): return PacketResource(url: client.browseURL(forIssue: key), details: ["Field: description", updated])
            default: return PacketResource(url: client.browseURL(forIssue: key), details: [updated])
            }
        case .confluencePage(let space, let id, _, _)?:
            // Without the page's facts the address is still worth giving.
            guard let document = try? await pageDocument(id, space: space) else { return PacketResource(url: client.site.appendingPathComponent("wiki/pages/\(id)")) }
            return PacketResource(url: client.pageURL(document.page), details: ["Version: \(document.page.version)"])
        default:
            return nil
        }
    }

    /// For the banner after a change: who made it and, for a page, its version ("Updated by Ana Ruiz · version 8").
    /// An issue's latest change is its newest field change or comment, whichever came last.
    public func changeSummary(for path: String) async -> String? {
        switch AtlassianPath(path) {
        case .jiraIssue(let project, let key)?:
            guard let document = try? await issueDocument(key, project: project) else { return nil }
            var latest: (author: String, at: Date)? = document.issue.comments.max { $0.created < $1.created }.map { ($0.author, $0.created) }
            if let change = try? await client.lastChange(ofIssue: key), change.at > (latest?.at ?? .distantPast) { latest = change }
            return latest.map { "Updated by \($0.author)" }
        case .confluencePage(let space, let id, _, _)?:
            guard let document = try? await pageDocument(id, space: space) else { return nil }
            var author: String?
            if let id = document.page.authorId { author = try? await client.userName(accountId: id) }
            return (author.map { "Updated by \($0) · " } ?? "Updated to ") + "version \(document.page.version)"
        default:
            return nil
        }
    }

    /// The document a page URL or an issue key opens, at the path the tree shows it: a page needs its title and
    /// its ancestors (asked of Confluence), so revealing it walks the tree's own folders. A path made before a
    /// rename or a move comes back with today's title and place.
    /// - allowUnplaced: when the ancestors cannot be read, a bare page reference still gets a path (at the top of
    ///   its space); otherwise nil, so nothing is moved on a guess.
    public func documentPath(for reference: AtlassianPath, allowUnplaced: Bool = false) async -> String? {
        switch reference {
        case .jiraIssue: return reference.path
        case .confluencePageFolder(let space, let id, _), .confluencePage(let space, let id, _, _):
            guard let document = try? await pageDocument(id, space: space) else { return nil }
            let title = AtlassianPath.fileTitle(document.page.title)
            guard let ancestors = try? await client.ancestors(ofPage: id) else {
                // Where it sits is unknown: a path to a page stays as it is (nil: nothing moves); a bare page
                // reference (a URL) opens the page at the top of its space rather than not at all.
                if case .confluencePageFolder = reference, allowUnplaced { return AtlassianPath.confluencePage(space: space, id: id, title: title).path }
                return nil
            }
            return AtlassianPath.confluencePage(space: space, id: id, title: title, ancestors: ancestors).path
        default: return nil
        }
    }

    /// `KEY · summary` or `Title · version n` for a document, once its facts are known.
    public func title(for path: String) async -> String? {
        switch AtlassianPath(path) {
        case .jiraIssue(let project, let key)?: return (try? await issueDocument(key, project: project)).map { "\(key) · \($0.issue.summary)" }
        case .confluencePage(let space, let id, _, _)?: return (try? await pageDocument(id, space: space)).map { "\($0.page.title) · version \($0.page.version)" }
        default: return nil
        }
    }
}
