import Core
import Foundation

/// Jira issues and Confluence pages as a small read-only tree on the `atlassian` host: `/jira/<PROJECT>/<KEY>.md`
/// (the issues the user is part of, listed by project) and `/confluence/<SPACE>/<page id>/<Title>.md` (a space's
/// pages, each page's folder holding the page and its children). Read with the user's token; never written.
public actor AtlassianFileSystem: FileSystemProvider {
    public nonisolated let hostID = HostID.atlassian
    private let client: AtlassianClient
    private let pollInterval: Duration

    struct IssueDocument {
        var issue: JiraIssue
        var data: Data
        var comments: [(range: ClosedRange<Int>, id: String)]
    }

    struct PageDocument {
        var page: ConfluencePage
        var spaceKey: String
        var data: Data
    }

    private final class Poller {
        var task: Task<Void, Never>?
        var continuations: [UUID: AsyncStream<FileSystemEvent>.Continuation] = [:]
    }

    private var issues: [String: IssueDocument] = [:]
    private var issueLists: [String: [JiraIssue.Summary]] = [:]
    private var spaces: [ConfluenceSpace]?
    private var pages: [String: PageDocument] = [:]
    private var pageTitles: [String: ConfluencePage] = [:]
    private var pollers: [String: Poller] = [:]
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

    // MARK: Jira

    private func issueDocument(_ key: String, project: String, refresh: Bool = false) async throws -> IssueDocument {
        if !refresh, let cached = issues[key] { return cached }
        do {
            let issue = try await client.issue(key: key)
            let rendered = AtlassianMarkdown.issue(issue, url: client.browseURL(forIssue: key))
            let document = IssueDocument(issue: issue, data: Data(rendered.text.utf8), comments: rendered.comments)
            issues[key] = document
            return document
        } catch {
            throw Self.fileSystemError(error, path: AtlassianPath.jiraIssue(project: project, key: key).path)
        }
    }

    /// The issues the user is part of in a project, most recently updated first.
    private func issueList(_ project: String, refresh: Bool = false) async throws -> [JiraIssue.Summary] {
        if !refresh, let cached = issueLists[project] { return cached }
        do {
            let list = try await client.searchIssues(jql: "project = \(project) AND (assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser()) ORDER BY updated DESC")
            issueLists[project] = list
            return list
        } catch {
            throw Self.fileSystemError(error, path: AtlassianPath.jiraProject(project).path)
        }
    }

    // MARK: Confluence

    private func space(_ key: String) async throws -> ConfluenceSpace {
        if spaces == nil {
            do { spaces = try await client.spaces() } catch { throw Self.fileSystemError(error, path: AtlassianPath.confluenceSpace(key).path) }
        }
        guard let space = spaces?.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else { throw FileSystemError.notFound(AtlassianPath.confluenceSpace(key).path) }
        return space
    }

    private func pageDocument(_ id: String, space: String, refresh: Bool = false) async throws -> PageDocument {
        if !refresh, let cached = pages[id] { return cached }
        do {
            let page = try await client.page(id: id)
            pageTitles[id] = page
            let document = PageDocument(page: page, spaceKey: space, data: Data(AtlassianMarkdown.page(page, spaceKey: space, url: client.pageURL(page)).utf8))
            pages[id] = document
            return document
        } catch {
            throw Self.fileSystemError(error, path: AtlassianPath.confluencePageFolder(space: space, id: id).path)
        }
    }

    private func entries(for pages: [ConfluencePage], space: String) -> [DirectoryEntry] {
        pages.map { page in
            pageTitles[page.id] = page
            return DirectoryEntry(name: AtlassianPath.fileTitle(page.title), path: AtlassianPath.confluencePageFolder(space: space, id: page.id).path, kind: .directory, mtime: page.versionDate, mode: 0o555)
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
            do { return entries(for: try await client.pages(inSpace: space.id), space: key) } catch { throw Self.fileSystemError(error, path: directory) }
        case .confluencePageFolder(let space, let id):
            let page = try await pageDocument(id, space: space)
            var entries = [DirectoryEntry(name: AtlassianPath.fileTitle(page.page.title) + ".md", path: AtlassianPath.confluencePage(space: space, id: id, title: AtlassianPath.fileTitle(page.page.title)).path, kind: .file, size: Int64(page.data.count), mtime: page.page.versionDate, mode: 0o444)]
            do { entries += self.entries(for: try await client.children(ofPage: id), space: space) } catch { throw Self.fileSystemError(error, path: directory) }
            return entries
        case .jiraIssue, .confluencePage:
            throw FileSystemError.notADirectory(directory)
        }
    }

    public func stat(_ path: String) async throws -> FileAttributes {
        switch try parse(path) {
        case .jiraRoot, .confluenceRoot, .jiraProject:
            return FileAttributes(kind: .directory, size: 0, mtime: Date(timeIntervalSince1970: 0), mode: 0o555)
        case .confluenceSpace(let key):
            _ = try await space(key)
            return FileAttributes(kind: .directory, size: 0, mtime: Date(timeIntervalSince1970: 0), mode: 0o555)
        case .jiraIssue(let project, let key):
            let document = try await issueDocument(key, project: project)
            return FileAttributes(kind: .file, size: Int64(document.data.count), mtime: document.issue.updated, mode: 0o444)
        case .confluencePageFolder(let space, let id):
            let document = try await pageDocument(id, space: space)
            return FileAttributes(kind: .directory, size: 0, mtime: document.page.versionDate ?? Date(timeIntervalSince1970: 0), mode: 0o555)
        case .confluencePage(let space, let id, let title):
            let document = try await pageDocument(id, space: space)
            guard AtlassianPath.fileTitle(document.page.title) == title else { throw FileSystemError.notFound(path) }
            return FileAttributes(kind: .file, size: Int64(document.data.count), mtime: document.page.versionDate ?? Date(timeIntervalSince1970: 0), mode: 0o444)
        }
    }

    public func read(_ path: String) async throws -> Data {
        switch try parse(path) {
        case .jiraIssue(let project, let key):
            return try await issueDocument(key, project: project).data
        case .confluencePage(let space, let id, let title):
            let document = try await pageDocument(id, space: space)
            guard AtlassianPath.fileTitle(document.page.title) == title else { throw FileSystemError.notFound(path) }
            return document.data
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
        case .confluencePage(let space, let id, _):
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
                return PacketResource(url: client.browseURL(forIssue: key), details: ["Comment: \(comment.id)"])
            }
            return PacketResource(url: client.browseURL(forIssue: key), details: ["Field: description", "Updated: \(AtlassianMarkdown.stamp(document.issue.updated))"])
        case .confluencePage(let space, let id, _)?:
            guard let document = try? await pageDocument(id, space: space) else { return nil }
            return PacketResource(url: client.pageURL(document.page), details: ["Version: \(document.page.version)"])
        default:
            return nil
        }
    }

    /// The document a page URL or an issue key opens: `/confluence/<space>/<id>/<Title>.md` needs the title.
    public func documentPath(for reference: AtlassianPath) async -> String? {
        switch reference {
        case .jiraIssue: return reference.path
        case .confluencePageFolder(let space, let id):
            guard let document = try? await pageDocument(id, space: space) else { return nil }
            return AtlassianPath.confluencePage(space: space, id: id, title: AtlassianPath.fileTitle(document.page.title)).path
        case .confluencePage: return reference.path
        default: return nil
        }
    }

    /// `KEY · summary` or `Title · version n` for a document, once its facts are known.
    public func title(for path: String) async -> String? {
        switch AtlassianPath(path) {
        case .jiraIssue(let project, let key)?: return (try? await issueDocument(key, project: project)).map { "\(key) · \($0.issue.summary)" }
        case .confluencePage(let space, let id, _)?: return (try? await pageDocument(id, space: space)).map { "\($0.page.title) · version \($0.page.version)" }
        default: return nil
        }
    }
}
