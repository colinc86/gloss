import Core
import Foundation

/// A pull request as a small read-only tree on the `github` host: its description and conversation as Markdown,
/// the changed files at the head commit, and the whole diff. Everything is read with the user's token and nothing
/// is ever written; the agent changes the pull request with its own tools.
public actor GitHubPullRequestFileSystem: FileSystemProvider {
    public nonisolated let hostID = HostID.github
    private var client: GitHubClient
    private let pollInterval: Duration

    struct Key: Hashable { var owner: String; var repo: String; var number: Int }

    struct Snapshot {
        var pull: GitHubPullRequest
        var files: [GitHubPullRequestFile]
        var issueComments: [GitHubComment]
        var reviewComments: [GitHubComment]
        var description: Data
        var descriptionBody: ClosedRange<Int>
        var reviewLines: [(range: ClosedRange<Int>, url: URL)]
        var conversation: Data
        var conversationLines: [(range: ClosedRange<Int>, url: URL)]
        var diff: Data?
    }

    private final class Poller {
        var task: Task<Void, Never>?
        var continuations: [UUID: (continuation: AsyncStream<FileSystemEvent>.Continuation, isRoot: Bool)] = [:]
    }

    private var snapshots: [Key: Snapshot] = [:]
    /// Fetches in flight, so callers arriving together share one set of requests.
    private var inflight: [Key: (id: UUID, task: Task<Snapshot, any Error>)] = [:]
    /// Bumped by `replaceClient`: a read that started with the old key may finish, but is not kept.
    private var generation = 0
    private var contents: [String: Data] = [:]
    private var pollers: [Key: Poller] = [:]

    /// A new key. Open documents and pollers carry on with it; the snapshots stay, so the next poll still
    /// compares against what the documents show and reports a head that moved meanwhile. File contents read with
    /// the old key are dropped, and reads already under way finish for their callers without being kept.
    public func replaceClient(_ client: GitHubClient) {
        self.client = client
        generation += 1
        contents = [:]
        inflight = [:]
    }
    /// Watchers whose stream ended before their registration ran.
    private var terminated: Set<UUID> = []

    public init(client: GitHubClient, pollInterval: Duration = .seconds(10)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    // MARK: Snapshots

    private func key(_ path: PullRequestPath) -> Key { Key(owner: path.owner, repo: path.repo, number: path.number) }

    private func parse(_ path: String) throws -> PullRequestPath {
        guard let parsed = PullRequestPath(path) else { throw FileSystemError.notFound(path) }
        return parsed
    }

    /// The pull request's facts, fetched once and kept until `watch` sees it change.
    func snapshot(for path: PullRequestPath, refresh: Bool = false) async throws -> Snapshot {
        let key = key(path)
        if !refresh, let cached = snapshots[key] { return cached }
        if let running = inflight[key] { return try await running.task.value }
        let client = client
        let started = generation
        let task = Task<Snapshot, any Error> {
            async let pull = client.pullRequest(owner: path.owner, repo: path.repo, number: path.number)
            async let files = client.pullRequestFiles(owner: path.owner, repo: path.repo, number: path.number)
            async let issueComments = client.issueComments(owner: path.owner, repo: path.repo, number: path.number)
            async let reviewComments = client.reviewComments(owner: path.owner, repo: path.repo, number: path.number)
            let (pullValue, fileValues, issues, reviews) = try await (pull, files, issueComments, reviewComments)
            let conversation = PullRequestMarkdown.conversation(issues)
            let description = PullRequestMarkdown.description(pullValue, files: fileValues, reviewComments: reviews, path: path)
            return Snapshot(
                pull: pullValue, files: fileValues, issueComments: issues, reviewComments: reviews,
                description: Data(description.text.utf8), descriptionBody: description.body, reviewLines: description.reviews,
                conversation: Data(conversation.text.utf8), conversationLines: conversation.lines, diff: nil
            )
        }
        let id = UUID()
        inflight[key] = (id, task)
        // Only this fetch's own entry goes: a fetch for a new key may have taken the slot meanwhile.
        defer { if inflight[key]?.id == id { inflight[key] = nil } }
        do {
            let snapshot = try await task.value
            guard generation == started else { return snapshot }
            if let previous = snapshots[key], previous.pull.head.sha != snapshot.pull.head.sha {
                // The old head's files are not coming back.
                let stale = "\(previous.pull.head.sha):"
                contents = contents.filter { !$0.key.hasPrefix(stale) }
            }
            snapshots[key] = snapshot
            return snapshot
        } catch let error as IntegrationError {
            throw Self.fileSystemError(error, path: path.path)
        }
    }

    nonisolated static func fileSystemError(_ error: IntegrationError, path: String) -> FileSystemError {
        switch error {
        case .notFound: .notFound(path)
        case .unauthorized(let message): .permissionDenied(message.isEmpty ? path : message)
        default: .io(error.message)
        }
    }

    private func content(of file: String, in snapshot: Snapshot, path: PullRequestPath) async throws -> Data {
        let cacheKey = "\(snapshot.pull.head.sha):\(path.repository):\(file)"
        if let cached = contents[cacheKey] { return cached }
        let started = generation
        do {
            let data = try await client.fileContent(owner: path.owner, repo: path.repo, path: file, ref: snapshot.pull.head.sha)
            if generation == started { contents[cacheKey] = data }
            return data
        } catch let error as IntegrationError {
            throw Self.fileSystemError(error, path: path.path)
        }
    }

    private func diff(for path: PullRequestPath) async throws -> Data {
        let snapshot = try await snapshot(for: path)
        if let diff = snapshot.diff { return diff }
        do {
            let data = Data(try await client.diff(owner: path.owner, repo: path.repo, number: path.number).utf8)
            // The pull request may have moved on during the fetch: only the same head keeps this diff.
            if var current = snapshots[key(path)], current.pull.head.sha == snapshot.pull.head.sha {
                current.diff = data
                snapshots[key(path)] = current
            }
            return data
        } catch let error as IntegrationError {
            throw Self.fileSystemError(error, path: path.path)
        }
    }

    /// Files present at head (removed ones are gone there), by git path.
    private func presentFiles(_ snapshot: Snapshot) -> [GitHubPullRequestFile] {
        snapshot.files.filter { $0.status != "removed" }
    }

    // MARK: FileSystemProvider

    public func list(_ directory: String) async throws -> [DirectoryEntry] {
        let path = try parse(directory)
        let snapshot = try await snapshot(for: path)
        let mtime = snapshot.pull.updatedAt
        if path.isRoot {
            return [
                DirectoryEntry(name: PullRequestPath.descriptionName, path: path.root + "/" + PullRequestPath.descriptionName, kind: .file, size: Int64(snapshot.description.count), mtime: mtime, mode: 0o444),
                DirectoryEntry(name: PullRequestPath.conversationName, path: path.root + "/" + PullRequestPath.conversationName, kind: .file, size: Int64(snapshot.conversation.count), mtime: mtime, mode: 0o444),
                DirectoryEntry(name: PullRequestPath.changesName, path: path.root + "/" + PullRequestPath.changesName, kind: .directory, mtime: mtime, mode: 0o555),
                DirectoryEntry(name: path.diffName, path: path.root + "/" + path.diffName, kind: .file, size: snapshot.diff.map { Int64($0.count) }, mtime: mtime, mode: 0o444),
            ]
        }
        guard path.isChangesDirectory else { throw FileSystemError.notADirectory(directory) }
        if let file = path.changedFile, presentFiles(snapshot).contains(where: { $0.filename == file }) { throw FileSystemError.notADirectory(directory) }
        let prefix = path.changedFile.map { $0 + "/" } ?? ""
        var names: [String: DirectoryEntry] = [:]
        for file in presentFiles(snapshot) where file.filename.hasPrefix(prefix) {
            let remainder = file.filename.dropFirst(prefix.count)
            guard !remainder.isEmpty else { continue }
            let name = String(remainder.split(separator: "/", maxSplits: 1)[0])
            let isDirectory = remainder.contains("/")
            let full = path.root + "/" + PullRequestPath.changesName + "/" + prefix + name
            if names[name] == nil {
                names[name] = DirectoryEntry(name: name, path: full, kind: isDirectory ? .directory : .file, size: nil, mtime: mtime, mode: isDirectory ? 0o555 : 0o444)
            }
        }
        guard !names.isEmpty || prefix.isEmpty else { throw FileSystemError.notFound(directory) }
        return names.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func stat(_ path: String) async throws -> FileAttributes {
        let parsed = try parse(path)
        let snapshot = try await snapshot(for: parsed)
        let mtime = snapshot.pull.updatedAt
        if parsed.isRoot { return FileAttributes(kind: .directory, size: 0, mtime: mtime, mode: 0o555) }
        switch parsed.rest {
        case PullRequestPath.descriptionName: return FileAttributes(kind: .file, size: Int64(snapshot.description.count), mtime: mtime, mode: 0o444)
        case PullRequestPath.conversationName: return FileAttributes(kind: .file, size: Int64(snapshot.conversation.count), mtime: mtime, mode: 0o444)
        case parsed.diffName: return FileAttributes(kind: .file, size: Int64(try await diff(for: parsed).count), mtime: mtime, mode: 0o444)
        case PullRequestPath.changesName: return FileAttributes(kind: .directory, size: 0, mtime: mtime, mode: 0o555)
        default: break
        }
        guard let file = parsed.changedFile else { throw FileSystemError.notFound(path) }
        if presentFiles(snapshot).contains(where: { $0.filename == file }) {
            return FileAttributes(kind: .file, size: Int64(try await content(of: file, in: snapshot, path: parsed).count), mtime: mtime, mode: 0o444)
        }
        if presentFiles(snapshot).contains(where: { $0.filename.hasPrefix(file + "/") }) {
            return FileAttributes(kind: .directory, size: 0, mtime: mtime, mode: 0o555)
        }
        throw FileSystemError.notFound(path)
    }

    public func read(_ path: String) async throws -> Data {
        let parsed = try parse(path)
        let snapshot = try await snapshot(for: parsed)
        switch parsed.rest {
        case PullRequestPath.descriptionName: return snapshot.description
        case PullRequestPath.conversationName: return snapshot.conversation
        case parsed.diffName: return try await diff(for: parsed)
        default: break
        }
        guard let file = parsed.changedFile, presentFiles(snapshot).contains(where: { $0.filename == file }) else { throw FileSystemError.notFound(path) }
        return try await content(of: file, in: snapshot, path: parsed)
    }

    public func writeAtomically(_ data: Data, to path: String, preservingModeFrom original: FileAttributes?) async throws -> FileAttributes { throw FileSystemError.permissionDenied(path) }
    public func makeDirectory(_ path: String) async throws { throw FileSystemError.permissionDenied(path) }
    public func rename(_ path: String, to newPath: String) async throws { throw FileSystemError.permissionDenied(path) }
    public func delete(_ path: String) async throws { throw FileSystemError.permissionDenied(path) }

    /// Polls the pull request while anyone watches it; a new head or update time refreshes everything and tells
    /// every watcher that every document under the root changed.
    public nonisolated func watch(_ path: String) -> AsyncStream<FileSystemEvent> {
        guard let parsed = PullRequestPath(path) else { return AsyncStream { $0.finish() } }
        let id = UUID()
        return AsyncStream { continuation in
            Task { await self.addWatcher(id, continuation: continuation, path: parsed) }
            continuation.onTermination = { _ in Task { await self.removeWatcher(id, path: parsed) } }
        }
    }

    private func addWatcher(_ id: UUID, continuation: AsyncStream<FileSystemEvent>.Continuation, path: PullRequestPath) {
        // The stream was dropped before this ran: nothing to feed, no poller to start.
        if terminated.remove(id) != nil {
            continuation.finish()
            return
        }
        let key = key(path)
        let poller = pollers[key] ?? Poller()
        poller.continuations[id] = (continuation, path.isRoot)
        pollers[key] = poller
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

    private func removeWatcher(_ id: UUID, path: PullRequestPath) {
        let key = key(path)
        guard let poller = pollers[key], poller.continuations[id] != nil else {
            terminated.insert(id)
            return
        }
        poller.continuations[id] = nil
        if poller.continuations.isEmpty {
            poller.task?.cancel()
            pollers[key] = nil
        }
    }

    private func poll(_ path: PullRequestPath) async {
        let key = key(path)
        guard let previous = snapshots[key], let latest = try? await client.pullRequest(owner: path.owner, repo: path.repo, number: path.number) else { return }
        guard latest.head.sha != previous.pull.head.sha || latest.updatedAt != previous.pull.updatedAt else { return }
        guard let fresh = try? await snapshot(for: path, refresh: true), let poller = pollers[key] else { return }
        let changed = documentPaths(in: fresh, path: path) + documentPaths(in: previous, path: path)
        for (continuation, isRoot) in poller.continuations.values {
            // Documents hear which paths changed; the root (the explorer) also re-lists the tree.
            continuation.yield(.changed(Array(Set(changed))))
            if isRoot { continuation.yield(.rescan(path.root)) }
        }
    }

    private func documentPaths(in snapshot: Snapshot, path: PullRequestPath) -> [String] {
        [path.root + "/" + PullRequestPath.descriptionName, path.root + "/" + PullRequestPath.conversationName, path.root + "/" + path.diffName]
            + presentFiles(snapshot).map { path.root + "/" + PullRequestPath.changesName + "/" + $0.filename }
    }

    // MARK: What the app asks beyond files

    /// The lines a changed file's patch touched; nil when GitHub sent no patch (a very large or binary file).
    public func changes(forPath path: String) async -> LineChanges? {
        guard let parsed = PullRequestPath(path), let file = parsed.changedFile, let snapshot = try? await snapshot(for: parsed),
              let patch = snapshot.files.first(where: { $0.filename == file })?.patch else { return nil }
        return PatchHunks.parse(patch)
    }

    /// For the packet: the pull request's URL and what in it the document is.
    public func resource(for path: String, line: Int? = nil) async -> PacketResource? {
        guard let parsed = PullRequestPath(path), let snapshot = try? await snapshot(for: parsed) else { return nil }
        let url = snapshot.pull.htmlUrl
        if let file = parsed.changedFile { return PacketResource(url: url, details: ["Path: \(file) at \(snapshot.pull.head.sha.prefix(7))"]) }
        switch parsed.rest {
        case PullRequestPath.descriptionName:
            // A review comment by its own link; the description by its field; the facts above it are the pull request.
            if let line, let review = snapshot.reviewLines.first(where: { $0.range.contains(line) }) {
                return PacketResource(url: url, details: ["Comment: \(review.url.absoluteString)"])
            }
            if let line, !snapshot.descriptionBody.contains(line) { return PacketResource(url: url) }
            return PacketResource(url: url, details: ["Field: description"])
        case PullRequestPath.conversationName:
            if let line, let comment = snapshot.conversationLines.first(where: { $0.range.contains(line) }) {
                return PacketResource(url: url, details: ["Comment: \(comment.url.absoluteString)"])
            }
            return PacketResource(url: url, details: ["Field: conversation"])
        default: return PacketResource(url: url)
        }
    }

    /// `owner/repo #123 · title` for a root, once its facts are known.
    public func title(forRoot path: String) async -> (reference: String, title: String, state: String)? {
        guard let parsed = PullRequestPath(path), parsed.isRoot, let snapshot = try? await snapshot(for: parsed) else { return nil }
        return ("\(parsed.repository) #\(parsed.number)", snapshot.pull.title, PullRequestMarkdown.state(of: snapshot.pull))
    }
}
