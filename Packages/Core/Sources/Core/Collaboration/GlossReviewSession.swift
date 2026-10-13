import Foundation
import Synchronization

/// What changed in an open review.
public enum GlossReviewChange: Sendable {
    /// The package's files changed (another Mac's write, or ours). The summary lists other authors' new records.
    case updated(GlossSnapshot, GlossChangeSummary)
    /// Conflict versions iCloud kept were merged.
    case merged(GlossMergeReport)
    case moved(URL)
    /// The package went away: sharing stopped, access revoked, or it was trashed.
    case deleted
    /// Upload, download or sharing state changed.
    case status(GlossSyncStatus)
    /// The package couldn't be read just now; the last snapshot still stands.
    case failed(String)
}

/// Records other authors added since the previous snapshot; the reader's own never count as new.
public struct GlossChangeSummary: Sendable, Hashable {
    public var newNotes: [NoteID] = []
    /// The same note with a new `rev`: its author sent an edit.
    public var editedNotes: [NoteID] = []
    public var newMessages: [MessageID] = []
    public var newEvents: [EventID] = []
    public var newAuthors: [AuthorID] = []
    /// `info.current` moved to a snapshot that has arrived.
    public var iterationChanged = false

    public init() {}

    public var isEmpty: Bool {
        newNotes.isEmpty && editedNotes.isEmpty && newMessages.isEmpty && newEvents.isEmpty && newAuthors.isEmpty && !iterationChanged
    }

    static func between(_ old: GlossSnapshot?, _ new: GlossSnapshot, me: AuthorID) -> GlossChangeSummary {
        var summary = GlossChangeSummary()
        guard let old else { return summary }
        let oldNotes = Dictionary(old.notes.map { ($0.id, $0.rev) }, uniquingKeysWith: { first, _ in first })
        let oldMessages = Set(old.messages.map(\.id))
        let oldEvents = Set(old.events.map(\.id))
        let oldAuthors = Set(old.authors.map(\.id))
        for note in new.notes where note.author != me {
            if let rev = oldNotes[note.id] {
                if rev != note.rev { summary.editedNotes.append(note.id) }
            } else {
                summary.newNotes.append(note.id)
            }
        }
        summary.newMessages = new.messages.filter { $0.author != me && !oldMessages.contains($0.id) }.map(\.id)
        summary.newEvents = new.events.filter { $0.author != me && !oldEvents.contains($0.id) }.map(\.id)
        summary.newAuthors = new.authors.filter { $0.id != me && !oldAuthors.contains($0.id) }.map(\.id)
        summary.iterationChanged = new.hasCurrentContent && (old.info.current != new.info.current || !old.hasCurrentContent)
        return summary
    }
}

/// iCloud's view of a package, from its resource values.
public struct GlossSyncStatus: Sendable, Hashable {
    public enum Download: Sendable, Hashable { case current, downloaded, notDownloaded }
    public enum Role: Sendable, Hashable { case owner, participant }

    public var isInICloud = false
    public var isUploaded = false
    public var isUploading = false
    public var uploadError: String?
    public var download: Download?
    public var hasUnresolvedConflicts = false
    public var isShared = false
    /// From iCloud, not from `Info.json`.
    public var role: Role?
    /// Nil when not shared or not known.
    public var canWrite: Bool?
    public var ownerName: PersonNameComponents?
    public var lastEditorName: PersonNameComponents?

    public init() {}

    static func read(_ url: URL) -> GlossSyncStatus {
        var url = url
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey,
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemIsSharedKey,
            .ubiquitousSharedItemCurrentUserRoleKey, .ubiquitousSharedItemCurrentUserPermissionsKey,
            .ubiquitousSharedItemOwnerNameComponentsKey, .ubiquitousSharedItemMostRecentEditorNameComponentsKey,
        ]
        var status = GlossSyncStatus()
        guard let values = try? url.resourceValues(forKeys: keys) else { return status }
        status.isInICloud = values.isUbiquitousItem ?? false
        status.isUploaded = values.ubiquitousItemIsUploaded ?? false
        status.isUploading = values.ubiquitousItemIsUploading ?? false
        status.uploadError = values.ubiquitousItemUploadingError?.localizedDescription
        switch values.ubiquitousItemDownloadingStatus {
        case .current?: status.download = .current
        case .downloaded?: status.download = .downloaded
        case .notDownloaded?: status.download = .notDownloaded
        default: status.download = nil
        }
        status.hasUnresolvedConflicts = values.ubiquitousItemHasUnresolvedConflicts ?? false
        status.isShared = values.ubiquitousItemIsShared ?? false
        switch values.ubiquitousSharedItemCurrentUserRole {
        case .owner?: status.role = .owner
        case .participant?: status.role = .participant
        default: status.role = nil
        }
        switch values.ubiquitousSharedItemCurrentUserPermissions {
        case .readWrite?: status.canWrite = true
        case .readOnly?: status.canWrite = false
        default: status.canWrite = nil
        }
        status.ownerName = values.ubiquitousSharedItemOwnerNameComponents
        status.lastEditorName = values.ubiquitousSharedItemMostRecentEditorNameComponents
        return status
    }
}

/// One open review package: reads and writes it through `NSFileCoordinator`, presents it (`NSFilePresenter`) to
/// hear about other Macs' writes, merges iCloud's conflict versions, and streams what changed.
///
/// Every method is synchronous and may block on file coordination (iCloud downloading, another process writing):
/// call it off the main actor. Changes are delivered on a background queue. Call `close()` when done.
public final class GlossReviewSession: Sendable {
    public let identity: GlossIdentity
    private let presenter: GlossPresenter
    private let queue = DispatchQueue(label: "com.cnc.gloss.review")
    private let state: Mutex<State>

    private struct State {
        var info: GlossInfo
        var last: GlossSnapshot?
        var signature: [String: String] = [:]
        var status: GlossSyncStatus?
        var observers: [UUID: AsyncStream<GlossReviewChange>.Continuation] = [:]
        var refreshScheduled = false
        var conflictsSuspected = false
        var closed = false
        var deleted = false
        /// Conflict versions a merge refused (another instance, a newer format): reported once, not retried.
        var unmergeable: Set<String> = []
        var timer: (any DispatchSourceTimer)?
        /// Until the next poll; see `poll()`.
        var pollDelay: TimeInterval = 0
        var heardSincePoll = false
    }

    /// The slowest the fallback poll gets once the presenter is known to work, or nothing has changed for a while.
    static let quietPollInterval: TimeInterval = 30
    private let pollInterval: TimeInterval?

    /// Opens a package and starts presenting it. `pollInterval` is the quickest fallback check for changes the
    /// presenter misses (nil turns it off); it backs off to 30 s while the presenter delivers or nothing changes.
    public init(url: URL, identity: GlossIdentity, pollInterval: TimeInterval? = 5) throws {
        self.identity = identity
        self.pollInterval = pollInterval
        let presenter = GlossPresenter(url: url)
        self.presenter = presenter
        // The signature first: a write landing during the read then differs from it, and the poll catches it.
        let signature = Self.signature(of: url)
        let snapshot = try Self.coordinatedRead(url, presenter: nil) { try GlossPackage(url: $0).read() }
        state = Mutex(State(info: snapshot.info, last: snapshot, signature: signature, status: GlossSyncStatus.read(url)))
        presenter.handler = { [weak self] event in self?.handle(event) }
        NSFileCoordinator.addFilePresenter(presenter)
        if let pollInterval {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.poll() }
            state.withLock { $0.timer = timer; $0.pollDelay = pollInterval }
            timer.resume()
        }
    }

    /// Writes a new review in `folder` (normally `GlossLocations.reviewsFolder()`) holding `seed` and `notes`, then
    /// opens it. Named "Review of <title>.gloss" unless `fileName` says otherwise, with " 2", " 3"… if taken. The
    /// package appears complete or not at all.
    public static func create(in folder: URL, fileName: String? = nil, seed: GlossReviewSeed, notes: [GlossNoteBundle],
                              identity: GlossIdentity, pollInterval: TimeInterval? = 5) throws -> GlossReviewSession {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = fileName ?? GlossLocations.defaultFileName(for: seed.title)
        // Another create can take the same name between choosing it and moving the package in; take the next one.
        for _ in 0..<20 {
            let destination = GlossLocations.availableURL(in: folder, name: name)
            do {
                try coordinatedWrite(destination, presenter: nil) { target in
                    _ = try GlossPackageWriter.create(
                        at: target, owner: identity.author, ownerName: identity.name, title: seed.title, kind: seed.kind, source: seed.source,
                        content: seed.content, contentFacts: seed.contentFacts, iteration: seed.iteration, gitCommit: seed.gitCommit,
                        at: seed.capturedAt) { writer in
                        _ = try writer.publish(notes, name: identity.name, at: seed.capturedAt)
                    }
                }
            } catch GlossPackageError.alreadyExists {
                continue
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            return try GlossReviewSession(url: destination, identity: identity, pollInterval: pollInterval)
        }
        throw GlossPackageError.alreadyExists(folder.appending(path: name).path)
    }

    // MARK: Reading

    /// Where the package is now; follows moves and renames.
    public var url: URL { presenter.presentedItemURL ?? presenter.initialURL }
    /// As of the last read.
    public var info: GlossInfo { state.withLock { $0.info } }
    public var isOwner: Bool { info.isOwner(identity.author) }

    /// A coordinated read right now.
    public func snapshot() throws -> GlossSnapshot {
        try coordinatedRead { try GlossPackage(url: $0).read() }
    }

    /// One file's bytes (an attachment, a snapshot), read coordinated. Only attachment and content paths are
    /// accepted, since the path comes from other people's records.
    public func readFile(_ path: String) throws -> Data {
        switch GlossPath(relativePath: path) {
        case .attachment, .content, .contentMember:
            guard !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { fallthrough }
        default:
            throw GlossPackageError.unreadable(path: path, reason: "Not an attachment or content path")
        }
        return try coordinatedRead { root in
            let package = GlossPackage(url: root)
            try package.checkPath(path)
            // Belt and braces: whatever the path resolves to must be a regular file inside the package.
            let file = package.fileURL(path).resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  (try? FileManager.default.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType == .typeRegular else {
                throw GlossPackageError.unsafePath(path)
            }
            return try Data(contentsOf: file)
        }
    }

    /// A new stream of changes; the first element is `.updated` with the current snapshot and an empty summary.
    /// It ends when the session closes or the consumer stops.
    public func changes() -> AsyncStream<GlossReviewChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: GlossReviewChange.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        // Registered and given the current snapshot under one lock, so no newer change can arrive before it.
        let open = state.withLock { state -> Bool in
            guard !state.closed, let last = state.last else { return false }
            state.observers[id] = continuation
            continuation.yield(.updated(last, GlossChangeSummary()))
            return true
        }
        if !open { continuation.finish() }
        return stream
    }

    public func status() -> GlossSyncStatus { GlossSyncStatus.read(url) }

    /// Asks iCloud to download the package if it was evicted.
    public func startDownloading() throws {
        guard status().isInICloud else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    public func close() {
        let (observers, timer) = state.withLock { state -> ([AsyncStream<GlossReviewChange>.Continuation], (any DispatchSourceTimer)?) in
            state.closed = true
            defer { state.observers = [:]; state.timer = nil }
            return (Array(state.observers.values), state.timer)
        }
        timer?.cancel()
        NSFileCoordinator.removeFilePresenter(presenter)
        presenter.handler = nil
        observers.forEach { $0.finish() }
    }

    // MARK: Writing

    /// Writes the bundles into this author's folder, skipping what's already published. See `GlossNoteBundle`.
    @discardableResult
    public func publish(_ bundles: [GlossNoteBundle]) throws -> GlossPublishReport {
        let report = try coordinatedWrite { target in
            try GlossPackageWriter(package: GlossPackage(url: target), author: identity.author).publish(bundles, name: identity.name, at: Date())
        }
        scheduleRefresh()
        return report
    }

    /// State changes on anyone's notes; ones already written are skipped. The writer refuses what this author may
    /// not do.
    public func record(_ events: [GlossEvent]) throws {
        try coordinatedWrite { target in
            let writer = try GlossPackageWriter(package: GlossPackage(url: target), author: identity.author)
            for event in events where !FileManager.default.fileExists(atPath: writer.package.fileURL(GlossLayout.event(event.id, by: identity.author)).path) {
                try writer.writeEvent(event)
            }
        }
        scheduleRefresh()
    }

    /// Thread turns; ones already written are skipped.
    public func post(_ messages: [GlossMessage]) throws {
        try coordinatedWrite { target in
            let writer = try GlossPackageWriter(package: GlossPackage(url: target), author: identity.author)
            for message in messages where !FileManager.default.fileExists(atPath: writer.package.fileURL(GlossLayout.message(message.id, by: identity.author)).path) {
                try writer.writeMessage(message)
            }
        }
        scheduleRefresh()
    }

    /// Owner: mirrors the owner's local iteration `number` in the package. The current bytes with a higher number
    /// advance the iteration on the existing snapshot. False, with nothing written, when `number` isn't past the
    /// current iteration and the bytes are the same.
    @discardableResult
    public func publishIteration(_ number: Int, content: GlossContent, contentFacts: JSONValue? = nil, gitCommit: String? = nil,
                                 name: String? = nil, at date: Date = Date()) throws -> Bool {
        let published = try coordinatedWrite { target in
            var writer = try GlossPackageWriter(package: GlossPackage(url: target), author: identity.author)
            return try writer.publish(iteration: number, content: content, contentFacts: contentFacts, gitCommit: gitCommit, name: name, at: date)
        }
        scheduleRefresh()
        return published
    }

    /// Same Apple Account on another Mac: when iCloud says this user owns the file, adds this install's author to
    /// the review's owners so owner-only writes work here too. Owned means a shared item whose role is owner, or an
    /// unshared item in iCloud Drive (only the account's own files are there unshared; iCloud reports no role for
    /// them). False when it already is one. Throws `notOwner` otherwise (a participant never adds itself) and
    /// `notAllowed` for a detached copy.
    @discardableResult
    public func adoptOwnership() throws -> Bool {
        try adoptOwnership(status: status())
    }

    func adoptOwnership(status: GlossSyncStatus) throws -> Bool {
        let owned = status.isShared ? status.role == .owner : status.isInICloud && status.role == nil
        guard owned else { throw GlossPackageError.notOwner }
        let adopted = try coordinatedWrite { target -> GlossInfo? in
            var writer = try GlossPackageWriter(package: GlossPackage(url: target), author: identity.author)
            return try writer.adoptOwnership(name: identity.name, at: Date()) ? writer.info : nil
        }
        guard let adopted else { return false }
        // `isOwner` answers true right away, not after the refresh.
        state.withLock { $0.info = adopted }
        scheduleRefresh()
        return true
    }

    /// Rewrites this author's `author.json` with a new name, keeping everything else in it.
    public func setName(_ name: String) throws {
        try coordinatedWrite { target in
            let package = GlossPackage(url: target)
            let path = GlossLayout.author(identity.author)
            var author = package.readIfSafe(path).flatMap { try? GlossCoding.decode(GlossAuthor.self, from: $0) }
                ?? GlossAuthor(id: identity.author, name: name, joinedAt: Date())
            author.name = name
            author.rev = ULID.generate()
            try GlossPackageWriter.write(GlossCoding.encode(author), to: package, path)
        }
        scheduleRefresh()
    }

    /// Send a Copy: a detached copy (new instance, with an origin) in a fresh temporary folder, for the share picker.
    /// The caller removes the folder when the share is done.
    public func makeCopy() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Gloss Copy \(ULID.generate())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: url.lastPathComponent, directoryHint: .isDirectory)
        do {
            _ = try coordinatedRead { try GlossPackage(url: $0).makeCopy(to: destination) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return destination
    }

    // MARK: Conflicts and duplicates

    /// Merges every unresolved conflict version iCloud kept, of the package and of each file in it, and marks them
    /// resolved. Nil when there were none.
    @discardableResult
    public func resolveConflictsNow() throws -> GlossMergeReport? {
        let report = try resolveConflicts(scanFiles: true)
        if let report { emit(.merged(report)) }
        scheduleRefresh()
        return report
    }

    /// Sibling packages with this review's instance, such as "Review of README 2.gloss" left by an offline
    /// duplicate.
    /// Only siblings named like this one ("Name.gloss", "Name 2.gloss"…) that are downloaded are opened, so this
    /// never makes iCloud download every review in the folder.
    public func duplicates() -> [URL] {
        let instance = info.instance
        let me = url.standardizedFileURL
        let base = Self.baseName(url.deletingPathExtension().lastPathComponent)
        return GlossLocations.reviews(in: [url.deletingLastPathComponent()]).filter { candidate in
            guard candidate.standardizedFileURL != me, Self.baseName(candidate.deletingPathExtension().lastPathComponent) == base,
                  FileManager.default.fileExists(atPath: candidate.path), GlossSyncStatus.read(candidate).download != .notDownloaded else { return false }
            let other = try? coordinatedRead(candidate) { try GlossPackage(url: $0).readInfo() }
            return other?.instance == instance
        }
    }

    /// "Review of README.md" for "Review of README.md 2".
    static func baseName(_ name: String) -> String {
        guard let space = name.lastIndex(of: " "), let number = Int(name[name.index(after: space)...]), number >= 2 else { return name }
        return String(name[..<space])
    }

    /// Merges a duplicate in, then moves it to the Trash.
    @discardableResult
    public func absorbDuplicate(_ duplicate: URL) throws -> GlossMergeReport {
        try absorbDuplicate(duplicate) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    }

    func absorbDuplicate(_ duplicate: URL, discard: (URL) throws -> Void) throws -> GlossMergeReport {
        var coordinationError: NSError?
        var result: Result<GlossMergeReport, any Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator(filePresenter: presenter).coordinate(
            writingItemAt: url, options: .forMerging, writingItemAt: duplicate, options: .forDeleting, error: &coordinationError
        ) { target, other in
            result = Result {
                let report = try GlossMerge.merge([other], into: target)
                try discard(other)
                return report
            }
        }
        if let coordinationError { throw coordinationError }
        let report = try result.get()
        emit(.merged(report))
        scheduleRefresh()
        return report
    }

    private func resolveConflicts(scanFiles: Bool) throws -> GlossMergeReport? {
        let root = url
        let skipped = state.withLock { $0.unmergeable }
        let packageVersions = (NSFileVersion.unresolvedConflictVersionsOfItem(at: root) ?? []).filter { !skipped.contains($0.url.path) }
        var fileConflicts: [String] = []
        if scanFiles {
            fileConflicts = GlossPackage(url: root).files().filter {
                !(NSFileVersion.unresolvedConflictVersionsOfItem(at: GlossPackage(url: root).fileURL($0)) ?? []).isEmpty
            }
        }
        guard !packageVersions.isEmpty || !fileConflicts.isEmpty else { return nil }
        return try coordinatedWrite(options: .forMerging) { target in
            let package = GlossPackage(url: target)
            var report = GlossMergeReport()
            let versions = (NSFileVersion.unresolvedConflictVersionsOfItem(at: target) ?? []).filter { !skipped.contains($0.url.path) }
            if !versions.isEmpty {
                do {
                    report = try GlossMerge.merge(versions.map(\.url), into: target)
                } catch {
                    // Kept as they are (nothing is thrown away) but not retried on every refresh.
                    state.withLock { $0.unmergeable.formUnion(versions.map(\.url.path)) }
                    throw error
                }
                for version in versions { version.isResolved = true }
                try NSFileVersion.removeOtherVersionsOfItem(at: target)
            }
            let current = try? package.readInfo().current
            for path in fileConflicts {
                let fileURL = package.fileURL(path)
                let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL) ?? []
                guard !versions.isEmpty else { continue }
                var contents = [package.readIfSafe(path)].compactMap { $0 } + versions.compactMap { try? Data(contentsOf: $0.url) }
                if path == GlossFormat.infoFile, let instance = try? package.readInfo().instance {
                    // Never adopt a conflict copy that names another review or carries an unsafe identifier.
                    contents = contents.filter { data in
                        (try? GlossCoding.decode(GlossInfo.self, from: data)).map { $0.instance == instance && $0.identifierProblem == nil } ?? false
                    }
                }
                if let winner = GlossMerge.pick(path, contents, current: current, manifests: Self.manifests(in: package, for: path), &report),
                   winner != package.readIfSafe(path) {
                    try GlossPackageWriter.write(winner, to: package, path)
                    report.written.append(path)
                }
                for version in versions { version.isResolved = true }
                try NSFileVersion.removeOtherVersionsOfItem(at: fileURL)
            }
            report.treeHash = try package.treeHash()
            return report
        }
    }

    /// The manifest of the folder capture `path` belongs to, when it is a member of one.
    private static func manifests(in package: GlossPackage, for path: String) -> [String: [String: String]] {
        guard case .contentMember(let hash) = GlossPath(relativePath: path),
              let data = package.readIfSafe(GlossFormat.contentFolder + "/" + hash + "/" + GlossFormat.manifestFile),
              data.sha256Hex == hash, let members = try? GlossCoding.decoder.decode([String: String].self, from: data) else { return [:] }
        return [hash: members]
    }

    // MARK: Watching

    private func handle(_ event: GlossPresenter.Event) {
        if case .deleted = event {} else { state.withLock { $0.heardSincePoll = true } }
        switch event {
        case .changed:
            scheduleRefresh()
        case .gainedVersion:
            state.withLock { $0.conflictsSuspected = true }
            scheduleRefresh()
        case .moved(let newURL):
            emit(.moved(newURL))
            scheduleRefresh()
        case .deleted:
            // Nothing left to watch: stop polling and refreshing, so a gone package doesn't fail every interval.
            let timer = state.withLock { state -> (any DispatchSourceTimer)? in
                state.deleted = true
                defer { state.timer = nil }
                return state.timer
            }
            timer?.cancel()
            emit(.deleted)
        }
    }

    /// Coalesces bursts of presenter callbacks into one refresh a quarter second later.
    func scheduleRefresh() {
        let schedule = state.withLock { state -> Bool in
            guard !state.closed, !state.refreshScheduled else { return false }
            state.refreshScheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            state.withLock { $0.refreshScheduled = false }
            refresh()
        }
    }

    /// The fallback check, rescheduled after each run: 30 s after the presenter delivered something (it works, so
    /// this is only a backstop), back to `pollInterval` when it finds a change the presenter didn't report, and
    /// doubling towards 30 s while nothing changes.
    private func poll() {
        guard let fastest = pollInterval, !state.withLock({ $0.closed || $0.deleted }) else { return }
        let changed = state.withLock { $0.signature } != Self.signature(of: url)
        if changed { refresh() } else { publishStatusIfChanged() }
        let slowest = max(Self.quietPollInterval, fastest)
        let (timer, delay) = state.withLock { state -> ((any DispatchSourceTimer)?, TimeInterval) in
            if state.heardSincePoll {
                state.pollDelay = slowest
            } else if changed {
                state.pollDelay = fastest
            } else {
                state.pollDelay = min(state.pollDelay * 2, slowest)
            }
            state.heardSincePoll = false
            return (state.timer, state.pollDelay)
        }
        timer?.schedule(deadline: .now() + delay, leeway: .milliseconds(500))
    }

    /// Until the next fallback check; for tests.
    var pollDelay: TimeInterval { state.withLock { $0.pollDelay } }

    /// On the queue: merge conflicts if there are any, re-read, and tell observers what changed.
    private func refresh() {
        guard !state.withLock({ $0.closed || $0.deleted }) else { return }
        let suspected = state.withLock { $0.conflictsSuspected }
        do {
            if let report = try resolveConflicts(scanFiles: suspected || status().hasUnresolvedConflicts) { emit(.merged(report)) }
            state.withLock { $0.conflictsSuspected = false }
        } catch {
            emit(.failed("Couldn't merge review updates: \(error.localizedDescription)"))
        }
        do {
            let signature = Self.signature(of: url)
            let snapshot = try self.snapshot()
            let summary = state.withLock { state -> GlossChangeSummary? in
                guard state.signature != signature || state.last == nil else { return nil }
                let summary = GlossChangeSummary.between(state.last, snapshot, me: identity.author)
                state.last = snapshot
                // Owners only join within an instance: a snapshot read before our adoption landed mustn't undo it.
                var info = snapshot.info
                if state.info.instance == info.instance, state.info.isOwner(identity.author) { info.addOwner(identity.author) }
                state.info = info
                state.signature = signature
                return summary
            }
            if let summary { emit(.updated(snapshot, summary)) }
        } catch {
            emit(.failed(String(describing: error)))
        }
        publishStatusIfChanged()
    }

    private func publishStatusIfChanged() {
        let status = status()
        let changed = state.withLock { state -> Bool in
            guard state.status != status else { return false }
            state.status = status
            return true
        }
        if changed { emit(.status(status)) }
    }

    private func emit(_ change: GlossReviewChange) {
        let observers = state.withLock { $0.closed ? [] : Array($0.observers.values) }
        observers.forEach { $0.yield(change) }
    }

    /// Each file's path with its size and modification time: cheap to compute, and different whenever a file
    /// arrives, changes or goes.
    static func signature(of url: URL) -> [String: String] {
        var signature: [String: String] = [:]
        for path in GlossPackage(url: url).files() {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.appending(path: path).path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            signature[path] = "\(size)@\(modified)"
        }
        return signature
    }

    // MARK: Coordination

    private func coordinatedRead<T>(_ target: URL? = nil, _ body: (URL) throws -> T) throws -> T {
        try Self.coordinatedRead(target ?? url, presenter: presenter, body)
    }

    private func coordinatedWrite<T>(options: NSFileCoordinator.WritingOptions = [], _ body: (URL) throws -> T) throws -> T {
        try Self.coordinatedWrite(url, options: options, presenter: presenter, body)
    }

    static func coordinatedRead<T>(_ url: URL, presenter: (any NSFilePresenter)?, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try body(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    static func coordinatedWrite<T>(_ url: URL, options: NSFileCoordinator.WritingOptions = [], presenter: (any NSFilePresenter)?,
                                    _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: options, error: &coordinationError) { target in
            result = Result { try body(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }
}

/// The `NSFilePresenter` for one package. Forwards what it hears; the session decides what to do.
final class GlossPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    enum Event: Sendable {
        case changed
        case gainedVersion
        case moved(URL)
        case deleted
    }

    let initialURL: URL
    private let location: Mutex<URL>
    private let handlerBox = Mutex<(@Sendable (Event) -> Void)?>(nil)
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.cnc.gloss.review.presenter"
        return queue
    }()

    init(url: URL) {
        initialURL = url
        location = Mutex(url)
    }

    var handler: (@Sendable (Event) -> Void)? {
        get { handlerBox.withLock { $0 } }
        set { handlerBox.withLock { $0 = newValue } }
    }

    var presentedItemURL: URL? { location.withLock { $0 } }

    /// Without this, `presentedItemDidChangeUbiquityAttributes` is never called: upload, download and sharing
    /// changes would only reach observers through the poll.
    var observedPresentedItemUbiquityAttributes: Set<URLResourceKey> {
        [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingStatusKey,
         .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemIsSharedKey, .ubiquitousSharedItemCurrentUserRoleKey,
         .ubiquitousSharedItemCurrentUserPermissionsKey]
    }

    private func send(_ event: Event) { handler?(event) }

    func presentedItemDidChange() { send(.changed) }
    func presentedSubitemDidChange(at url: URL) { send(.changed) }
    func presentedSubitemDidAppear(at url: URL) { send(.changed) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { send(.changed) }
    func presentedItemDidChangeUbiquityAttributes(_ attributes: Set<URLResourceKey>) { send(.changed) }
    func presentedItemDidGain(_ version: NSFileVersion) { send(.gainedVersion) }
    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { send(.gainedVersion) }
    func presentedItemDidResolveConflict(_ version: NSFileVersion) { send(.changed) }

    func presentedItemDidMove(to newURL: URL) {
        location.withLock { $0 = newURL }
        send(.moved(newURL))
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        send(.deleted)
        completionHandler(nil)
    }
}
