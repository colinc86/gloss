import Foundation

/// Something in a package that couldn't be used: unreadable JSON, a record in the wrong author's folder, a file whose
/// name doesn't match its record. The rest of the package still reads.
public struct GlossIssue: Hashable, Sendable {
    public var path: String
    public var problem: String

    public init(path: String, problem: String) {
        self.path = path
        self.problem = problem
    }
}

/// Everything a package holds, read at one moment.
public struct GlossSnapshot: Sendable {
    public var info: GlossInfo
    public var iterations: [GlossIteration] = []
    public var authors: [GlossAuthor] = []
    public var notes: [GlossNote] = []
    public var messages: [GlossMessage] = []
    public var events: [GlossEvent] = []
    /// Relative paths of every author's attachments.
    public var attachments: [String] = []
    /// Hashes of the snapshots present under `content/`.
    public var snapshots: Set<String> = []
    public var issues: [GlossIssue] = []

    public func author(_ id: AuthorID) -> GlossAuthor? { authors.first { $0.id == id } }

    /// True once the current snapshot has arrived: a reader adopts `info.current` only then.
    public var hasCurrentContent: Bool { snapshots.contains(info.current.hash) }

    /// Every note with its state folded from the events.
    public func folded() -> [GlossNoteState] { GlossFold.fold(self) }
}

/// A `.gloss` package on disk. Reads with plain file access; coordinating with iCloud is the caller's job.
public struct GlossPackage: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func fileURL(_ relativePath: String) -> URL {
        url.appending(path: relativePath, directoryHint: .notDirectory)
    }

    /// Info.json, refused unless every identifier in it is canonical: they name folders and index rows, so one
    /// like `../x` would reach outside the package.
    public func readInfo() throws -> GlossInfo {
        let infoURL = fileURL(GlossFormat.infoFile)
        guard FileManager.default.fileExists(atPath: infoURL.path) else { throw GlossPackageError.notAPackage(url.path) }
        try checkPath(GlossFormat.infoFile)
        let info: GlossInfo
        do {
            info = try GlossCoding.decode(GlossInfo.self, from: Data(contentsOf: infoURL))
        } catch {
            throw GlossPackageError.unreadable(path: GlossFormat.infoFile, reason: String(describing: error))
        }
        guard info.minReader <= GlossFormat.version else { throw GlossPackageError.needsNewerReader(info.minReader) }
        if let problem = info.identifierProblem {
            throw GlossPackageError.unreadable(path: GlossFormat.infoFile, reason: problem)
        }
        return info
    }

    /// The file's bytes when `relativePath` is a regular file reached without links; nil otherwise. Reading
    /// through a link someone planted (to `/dev/zero`, a FIFO) could hang or leak.
    func readIfSafe(_ relativePath: String) -> Data? {
        guard isRegularFile(relativePath) else { return nil }
        return try? Data(contentsOf: fileURL(relativePath))
    }

    func isRegularFile(_ relativePath: String) -> Bool {
        guard (try? checkPath(relativePath)) != nil else { return false }
        return (try? FileManager.default.attributesOfItem(atPath: fileURL(relativePath).path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// Throws `unsafePath` when a part of `relativePath` that exists is a symbolic link or anything but a folder or
    /// a regular file, or when it climbs out with `..`. Parts that don't exist yet are fine (a write creates them).
    func checkPath(_ relativePath: String) throws {
        var current = url
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != "..", component != "." else { throw GlossPackageError.unsafePath(relativePath) }
            current = current.appending(path: String(component))
            // attributesOfItem doesn't follow a final link, so a link reads as `.typeSymbolicLink`.
            guard let type = (try? FileManager.default.attributesOfItem(atPath: current.path))?[.type] as? FileAttributeType else { return }
            guard type == .typeDirectory || type == .typeRegular else { throw GlossPackageError.unsafePath(relativePath) }
        }
    }

    /// Relative paths of every regular file, sorted. Hidden files (Finder's, iCloud's placeholders) are left out.
    public func files() -> [String] {
        Self.files(under: url)
    }

    static func files(under url: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return [] }
        var paths: [String] = []
        while let path = enumerator.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".") {
                if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular { paths.append(path) }
        }
        return paths.sorted()
    }

    /// The file or folder holding the snapshot with this hash, when it has arrived. Never a link. Read a folder
    /// capture's members with `GlossReviewSession.readFile`, which checks each one.
    public func contentURL(hash: String) -> URL? {
        guard GlossPath.isHash(hash) else { return nil }
        let folder = url.appending(path: GlossFormat.contentFolder, directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let name = names.sorted().first(where: { $0 == hash || $0.hasPrefix(hash + ".") }),
              (try? checkPath(GlossFormat.contentFolder + "/" + name)) != nil else { return nil }
        return folder.appending(path: name)
    }

    /// One hash over every file's path and bytes: equal on two Macs exactly when their packages hold the same files.
    public func treeHash() throws -> String {
        var lines = ""
        for path in files() {
            lines += path + "\u{0}" + (try Data(contentsOf: fileURL(path))).sha256Hex + "\n"
        }
        return Data(lines.utf8).sha256Hex
    }

    public func read() throws -> GlossSnapshot {
        var snapshot = GlossSnapshot(info: try readInfo())
        var notes: [(path: String, note: GlossNote)] = []

        func load<T: GlossRecord>(_ type: T.Type, _ path: String) -> T? {
            do {
                return try GlossCoding.decode(type, from: Data(contentsOf: fileURL(path)))
            } catch {
                snapshot.issues.append(GlossIssue(path: path, problem: "Unreadable: \(error)"))
                return nil
            }
        }
        func reject(_ path: String, _ problem: String) {
            snapshot.issues.append(GlossIssue(path: path, problem: problem))
        }

        for path in files() {
            switch GlossPath(relativePath: path) {
            case .info, .other:
                continue
            case .contentMember(let hash):
                // A folder capture has arrived once its manifest has and every member it lists is there.
                guard path == GlossFormat.contentFolder + "/" + hash + "/" + GlossFormat.manifestFile,
                      let data = try? Data(contentsOf: fileURL(path)), data.sha256Hex == hash,
                      let members = try? GlossCoding.decoder.decode([String: String].self, from: data),
                      members.keys.allSatisfy({ FileManager.default.fileExists(atPath: fileURL(GlossFormat.contentFolder + "/" + hash + "/" + $0).path) })
                else { continue }
                snapshot.snapshots.insert(hash)
            case .content(let hash):
                snapshot.snapshots.insert(hash)
            case .iteration(let number):
                guard let iteration = load(GlossIteration.self, path) else { continue }
                guard iteration.number == number else { reject(path, "Holds iteration \(iteration.number)"); continue }
                snapshot.iterations.append(iteration)
            case .author(let folder):
                guard let author = load(GlossAuthor.self, path) else { continue }
                guard author.id == folder else { reject(path, "Names author \(author.id) in another author's folder"); continue }
                snapshot.authors.append(author)
            case .note(let folder, let id):
                guard let note = load(GlossNote.self, path) else { continue }
                guard note.author == folder else { reject(path, "Written by \(note.author) in another author's folder"); continue }
                guard note.id == id else { reject(path, "Holds note \(note.id)"); continue }
                var checked = note
                if let refs = note.attachments {
                    // Only the author's own attachments folder; anything else could point outside the package.
                    checked.attachments = refs.filter {
                        guard case .attachment(let owner, _) = GlossPath(relativePath: $0.path), owner == folder else { return false }
                        return true
                    }
                    if checked.attachments?.count != refs.count { reject(path, "Refers to attachments outside its author's folder") }
                }
                // Agents work on the owner's Mac: only an owner's record can name one.
                if !snapshot.info.isOwner(note.author) { checked.via = nil }
                notes.append((path, checked))
            case .message(let folder, let id):
                guard let message = load(GlossMessage.self, path) else { continue }
                guard message.author == folder else { reject(path, "Written by \(message.author) in another author's folder"); continue }
                guard message.id == id else { reject(path, "Holds message \(message.id)"); continue }
                var checked = message
                if !snapshot.info.isOwner(message.author) { checked.via = nil }
                snapshot.messages.append(checked)
            case .event(let folder, let id):
                guard let event = load(GlossEvent.self, path) else { continue }
                guard event.author == folder else { reject(path, "Written by \(event.author) in another author's folder"); continue }
                guard event.id == id else { reject(path, "Holds event \(event.id)"); continue }
                snapshot.events.append(event)
            case .attachment:
                snapshot.attachments.append(path)
            }
        }
        // A note id in two authors' folders can't be told apart from a forgery, so neither copy is used.
        let counts = Dictionary(grouping: notes, by: \.note.id).mapValues(\.count)
        for (path, note) in notes {
            if counts[note.id] == 1 { snapshot.notes.append(note) } else { reject(path, "Note \(note.id) is in more than one author's folder") }
        }
        // Sorted, so the order is the same on every Mac; notes and turns read in creation order.
        snapshot.iterations.sort { $0.number < $1.number }
        snapshot.messages.sort { $0.id.rawValue < $1.id.rawValue }
        snapshot.events.sort { $0.id.rawValue < $1.id.rawValue }
        snapshot.notes.sort { $0.id.rawValue < $1.id.rawValue }
        return snapshot
    }

    /// The author whose folder holds a note, when it has arrived.
    public func author(ofNote id: NoteID) -> AuthorID? {
        let authors = url.appending(path: GlossFormat.authorsFolder, directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: authors.path)) ?? []
        for folder in folders.sorted() {
            guard let author = AuthorID(validating: folder) else { continue }
            if isRegularFile(GlossLayout.note(id, by: author)) { return author }
        }
        return nil
    }
}

/// Writes a package as one author. Each author writes only their own folder; the owner also writes `Info.json`,
/// `content/` and `iterations/`. Write-once files are refused if they'd change. Writes are atomic per file but not
/// coordinated: the app wraps them in `NSFileCoordinator` for iCloud.
public struct GlossPackageWriter: Sendable {
    public let package: GlossPackage
    public let author: AuthorID
    public private(set) var info: GlossInfo

    public init(package: GlossPackage, author: AuthorID) throws {
        self.package = package
        self.author = author
        self.info = try package.readInfo()
    }

    public var isOwner: Bool { info.isOwner(author) }

    /// Creates a review package holding its first snapshot, its first iteration and the owner's author record. It is
    /// built beside `url` under a hidden name and moved into place, so nobody sees a half-written package.
    public static func create(
        at url: URL, owner: AuthorID, ownerName: String, title: String, kind: DocumentKind, source: GlossSource,
        content: Data, ext: String?, contentFacts: JSONValue? = nil, iteration: Int = 0, gitCommit: String? = nil, at date: Date = Date()
    ) throws -> GlossPackageWriter {
        try create(at: url, owner: owner, ownerName: ownerName, title: title, kind: kind, source: source, content: .file(content, ext: ext),
                   contentFacts: contentFacts, iteration: iteration, gitCommit: gitCommit, at: date)
    }

    public static func create(
        at url: URL, owner: AuthorID, ownerName: String, title: String, kind: DocumentKind, source: GlossSource,
        content: GlossContent, contentFacts: JSONValue? = nil, iteration: Int = 0, gitCommit: String? = nil, at date: Date = Date(),
        prepare: ((GlossPackageWriter) throws -> Void)? = nil
    ) throws -> GlossPackageWriter {
        if let problem = source.privacyProblem { throw GlossPackageError.unsafeSource(problem) }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw GlossPackageError.alreadyExists(url.path) }
        let staging = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(ULID.generate())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let package = GlossPackage(url: staging)
            let hash = try Self.writeContent(content, to: package)
            let first = GlossIteration(number: iteration, startedAt: date, snapshot: hash, gitCommit: gitCommit)
            try Self.write(GlossCoding.encode(first), to: package, GlossLayout.iteration(iteration))
            let info = GlossInfo(
                id: .new(), instance: .new(), createdAt: date, ownerAuthor: owner, kind: kind, title: title, source: source,
                current: GlossCurrent(hash: hash, iteration: iteration, capturedAt: date), content: contentFacts)
            try Self.write(GlossCoding.encode(GlossAuthor(id: owner, name: ownerName, joinedAt: date)), to: package, GlossLayout.author(owner))
            try Self.write(GlossCoding.encode(info), to: package, GlossFormat.infoFile)
            // Anything else the new package starts with (the owner's sent notes) goes in before anyone can see it.
            if let prepare { try prepare(GlossPackageWriter(package: package, author: owner)) }
            try FileManager.default.moveItem(at: staging, to: url)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return try GlossPackageWriter(package: GlossPackage(url: url), author: owner)
    }

    // MARK: Owner

    /// Rewrites `Info.json` with a fresh `rev`. The review and instance identifiers never change here.
    public mutating func writeInfo(_ updated: GlossInfo) throws {
        guard isOwner else { throw GlossPackageError.notOwner }
        if let problem = updated.source.privacyProblem { throw GlossPackageError.unsafeSource(problem) }
        guard updated.id == info.id, updated.instance == info.instance else { throw GlossPackageError.differentInstances }
        var stamped = updated
        stamped.rev = ULID.generate()
        try Self.write(GlossCoding.encode(stamped), to: package, GlossFormat.infoFile)
        info = stamped
    }

    /// Adds this author to the owners: another install of the owner's Apple Account. Only for when iCloud says this
    /// user owns the file (`GlossReviewSession.adoptOwnership()` checks); a participant never adds itself. A detached
    /// copy (Send a Copy) has no owner to adopt. Writes `author.json` if it's missing. False when already an owner.
    mutating func adoptOwnership(name: String, at date: Date) throws -> Bool {
        guard !isOwner else { return false }
        guard info.origin?.review != info.id else { throw GlossPackageError.notAllowed("A copy of a review has no owner to join") }
        if !FileManager.default.fileExists(atPath: package.fileURL(GlossLayout.author(author)).path) {
            try writeAuthor(name: name, joinedAt: date)
        }
        var updated = info
        updated.addOwner(author)
        updated.rev = ULID.generate()
        try Self.write(GlossCoding.encode(updated), to: package, GlossFormat.infoFile)
        info = updated
        return true
    }

    /// Adds a snapshot named by its hash and returns the hash.
    @discardableResult
    public func addSnapshot(_ data: Data, ext: String?) throws -> String {
        try addSnapshot(.file(data, ext: ext))
    }

    /// Adds a multi-file capture (a web page's DOM and screenshot); see `GlossContent.folder`.
    @discardableResult
    public func addSnapshotFolder(_ files: [String: Data]) throws -> String {
        try addSnapshot(.folder(files))
    }

    @discardableResult
    public func addSnapshot(_ content: GlossContent) throws -> String {
        guard isOwner else { throw GlossPackageError.notOwner }
        return try Self.writeContent(content, to: package)
    }

    /// Writes a snapshot, write-once, and returns its hash. A folder is built under a hidden name and moved into
    /// place whole.
    static func writeContent(_ content: GlossContent, to package: GlossPackage) throws -> String {
        switch content {
        case .file(let data, let ext):
            let hash = data.sha256Hex
            try writeOnce(data, to: package, GlossLayout.content(hash: hash, ext: ext))
            return hash
        case .folder(let files):
            let manifest = try GlossContent.manifest(of: files)
            let hash = manifest.sha256Hex
            let folder = GlossFormat.contentFolder + "/" + hash
            if let existing = package.readIfSafe(folder + "/" + GlossFormat.manifestFile) {
                guard existing == manifest else { throw GlossPackageError.writeOnceConflict(folder) }
                return hash
            }
            let staging = GlossFormat.contentFolder + "/." + hash + "." + ULID.generate()
            do {
                for (name, data) in files { try write(data, to: package, staging + "/" + name) }
                try write(manifest, to: package, staging + "/" + GlossFormat.manifestFile)
                try FileManager.default.moveItem(at: package.fileURL(staging), to: package.fileURL(folder))
            } catch {
                try? FileManager.default.removeItem(at: package.fileURL(staging))
                throw error
            }
            return hash
        }
    }

    public func writeIteration(_ iteration: GlossIteration) throws {
        guard isOwner else { throw GlossPackageError.notOwner }
        var stamped = iteration
        stamped.rev = ULID.generate()
        try Self.write(GlossCoding.encode(stamped), to: package, GlossLayout.iteration(iteration.number))
    }

    /// Publishes the owner's local iteration `number`: ends the current iteration, adds the snapshot, writes the new
    /// iteration and only then points `Info.json` at it, so a reader never follows a pointer to content that isn't
    /// there. The package mirrors the owner's numbering: a higher number with the current bytes starts the iteration
    /// on the existing snapshot (no new capture, `capturedAt` kept). Returns false, writing nothing, when `number`
    /// isn't past the current iteration and the bytes are the current snapshot's; different bytes need a higher number.
    @discardableResult
    public mutating func publish(iteration number: Int, content: Data, ext: String?, contentFacts: JSONValue? = nil,
                                 gitCommit: String? = nil, name: String? = nil, at date: Date) throws -> Bool {
        try publish(iteration: number, content: .file(content, ext: ext), contentFacts: contentFacts, gitCommit: gitCommit, name: name, at: date)
    }

    @discardableResult
    public mutating func publish(iteration number: Int, content: GlossContent, contentFacts: JSONValue? = nil,
                                 gitCommit: String? = nil, name: String? = nil, at date: Date) throws -> Bool {
        guard isOwner else { throw GlossPackageError.notOwner }
        let hash = try content.hash()
        let sameBytes = hash == info.current.hash
        guard number > info.current.iteration else {
            if sameBytes { return false }
            throw GlossPackageError.iterationNotAfterCurrent(number)
        }
        let currentPath = GlossLayout.iteration(info.current.iteration)
        if let data = package.readIfSafe(currentPath), var ending = try? GlossCoding.decode(GlossIteration.self, from: data), ending.endedAt == nil {
            ending.endedAt = date
            try writeIteration(ending)
        }
        if !sameBytes { try addSnapshot(content) }
        try writeIteration(GlossIteration(number: number, name: name, startedAt: date, snapshot: hash, gitCommit: gitCommit))
        var updated = info
        updated.current = GlossCurrent(hash: hash, iteration: number, capturedAt: sameBytes ? info.current.capturedAt : date)
        updated.content = contentFacts
        try writeInfo(updated)
        return true
    }

    // MARK: Every author

    public func writeAuthor(name: String, color: String? = nil, joinedAt: Date) throws {
        try Self.write(GlossCoding.encode(GlossAuthor(id: author, name: name, color: color, joinedAt: joinedAt)), to: package, GlossLayout.author(author))
    }

    /// Writes (or rewrites, after an edit the author sent) one of the author's own notes, with a fresh `rev`.
    @discardableResult
    public func writeNote(_ note: GlossNote) throws -> GlossNote {
        guard note.author == author else { throw GlossPackageError.notYourFolder(note.author) }
        var stamped = note
        stamped.rev = ULID.generate()
        try Self.write(GlossCoding.encode(stamped), to: package, GlossLayout.note(note.id, by: author))
        return stamped
    }

    public func writeMessage(_ message: GlossMessage) throws {
        guard message.author == author else { throw GlossPackageError.notYourFolder(message.author) }
        try Self.writeOnce(GlossCoding.encode(message), to: package, GlossLayout.message(message.id, by: author))
    }

    /// Writes an event, refusing what this author may not do: `sent` and `accepted` are the owner's; deleting,
    /// restoring and moving a note are its author's or the owner's. Resolve and reopen are anyone's.
    public func writeEvent(_ event: GlossEvent) throws {
        guard event.author == author else { throw GlossPackageError.notYourFolder(event.author) }
        switch event.eventType {
        case .sent?, .accepted?:
            guard isOwner else { throw GlossPackageError.notOwner }
        case .deleted?, .restored?, .moved?:
            guard !isOwner else { break }
            guard let noteAuthor = package.author(ofNote: event.note) else { throw GlossPackageError.noSuchNote(event.note) }
            guard noteAuthor == author else { throw GlossPackageError.notAllowed("Only the note's author or the owner can \(event.type) it") }
        case .resolved?, .reopened?, nil:
            break
        }
        try Self.writeOnce(GlossCoding.encode(event), to: package, GlossLayout.event(event.id, by: author))
    }

    /// Adds an image the author's note refers to (a crop, a page render) and returns its path in the package.
    @discardableResult
    public func addAttachment(_ data: Data, ext: String?) throws -> String {
        let path = GlossLayout.attachment(hash: data.sha256Hex, ext: ext, by: author)
        try Self.writeOnce(data, to: package, path)
        return path
    }

    // MARK: Files

    static func write(_ data: Data, to package: GlossPackage, _ path: String) throws {
        // Never through a link someone else put in the package.
        try package.checkPath(path)
        let url = package.fileURL(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Writes a file that never changes once written: the same bytes again is a no-op, different bytes are refused.
    static func writeOnce(_ data: Data, to package: GlossPackage, _ path: String) throws {
        try package.checkPath(path)
        if let existing = package.readIfSafe(path) {
            guard existing == data else { throw GlossPackageError.writeOnceConflict(path) }
            return
        }
        try write(data, to: package, path)
    }
}
