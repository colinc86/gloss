import Foundation

/// The `.gloss` review package, format v1: one document's captured content, the notes people published on it and
/// its iterations, shared through iCloud Drive. Every file inside has exactly one writer (the owner writes
/// `Info.json`, `content/` and `iterations/`; each author writes only under `authors/<authorID>/`), so two Macs never
/// write the same file and merging is a union. Drafts never enter a package.
public enum GlossFormat {
    /// The format this Gloss writes and the newest it reads.
    public static let version = 1
    public static let fileExtension = "gloss"
    /// Declared by the app once collaboration ships; nothing registers it yet.
    public static let typeIdentifier = "com.cnc.gloss.document"

    public static let infoFile = "Info.json"
    public static let contentFolder = "content"
    public static let iterationsFolder = "iterations"
    public static let authorsFolder = "authors"
    public static let authorFile = "author.json"
    public static let notesFolder = "notes"
    public static let messagesFolder = "messages"
    public static let eventsFolder = "events"
    public static let attachmentsFolder = "attachments"
    /// `content/<hash>/manifest.json`: a folder capture's member names and their hashes; the folder is named by the
    /// manifest's hash.
    public static let manifestFile = "manifest.json"
}

/// The review a package holds. Stays the same when a package is moved or copied, so a copy can say where it came
/// from; a copy is told apart by its `InstanceID`.
public struct ReviewID: PrefixedIdentifier {
    public static let prefix = "g_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// One live package. Everyone collaborating on a review opens the same instance; Send a Copy mints a new one, and
/// packages with different instances never merge. The local index keys reviews by it.
public struct InstanceID: PrefixedIdentifier {
    public static let prefix = "i_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A person writing in a review: minted once per Gloss install, with the name they choose. Self-asserted among the
/// people the owner invited; not a verified identity.
public struct AuthorID: PrefixedIdentifier {
    public static let prefix = "u_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A state change on a note (`events/<id>.json`). Events fold in identifier order, which is creation order.
public struct EventID: PrefixedIdentifier {
    public static let prefix = "e_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// An identifier derived from what the event says: the time's milliseconds, then 80 bits of a SHA-256 of the
    /// note, type, author and time. Recording the same transition twice gives the same identifier, so a retried
    /// publish never duplicates an event.
    public static func derived(note: NoteID, type: GlossEventType, author: AuthorID, at date: Date) -> EventID {
        let milliseconds = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded()))
        let digest = Data("\(note.rawValue)|\(type.rawValue)|\(author.rawValue)|\(milliseconds)".utf8).sha256Hex
        let random = UInt128(digest.prefix(20), radix: 16) ?? 0
        return EventID(rawValue: prefix + ULID.encode(UInt128(milliseconds) << 80 | random))
    }
}

/// A snapshot's bytes.
public enum GlossContent: Sendable, Hashable {
    /// One file (text, code, markdown, CSV, image, PDF, anything), stored as `content/<sha256>.<ext>`.
    case file(Data, ext: String?)
    /// A multi-file capture (a web page's `dom.html` and `shot.png`), stored as `content/<hash>/…` with a
    /// `manifest.json` of each member's hash; `hash` is the manifest's. Names are relative paths without hidden or
    /// empty components.
    case folder([String: Data])

    /// The hash the snapshot is stored under.
    public func hash() throws -> String {
        switch self {
        case .file(let data, _): data.sha256Hex
        case .folder(let files): try Self.manifest(of: files).sha256Hex
        }
    }

    /// The manifest's bytes, after checking every name.
    static func manifest(of files: [String: Data]) throws -> Data {
        guard !files.isEmpty else { throw GlossPackageError.invalidFolderCapture("No files") }
        for name in files.keys {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard name != GlossFormat.manifestFile, !parts.contains(where: { $0.isEmpty || $0.hasPrefix(".") }),
                  !files.keys.contains(where: { $0.hasPrefix(name + "/") }) else { throw GlossPackageError.invalidFolderCapture(name) }
        }
        return try GlossCoding.encoder.encode(files.mapValues(\.sha256Hex))
    }
}

public enum GlossPackageError: Error, Equatable, Sendable {
    case notAPackage(String)
    case alreadyExists(String)
    case unreadable(path: String, reason: String)
    /// The package needs a newer Gloss (`minReader` is above `GlossFormat.version`).
    case needsNewerReader(Int)
    /// A write-once file already exists with different bytes.
    case writeOnceConflict(String)
    /// Only the review's owner writes this.
    case notOwner
    /// A record's author isn't the writer: each author writes only their own folder.
    case notYourFolder(AuthorID)
    /// The note's author or the owner may do this; nobody else.
    case notAllowed(String)
    case noSuchNote(NoteID)
    /// `source` names something private to the owner's Mac, such as an absolute path.
    case unsafeSource(String)
    /// The iteration published must come after the current one.
    case iterationNotAfterCurrent(Int)
    /// Packages with different instance identifiers are different reviews and never merge.
    case differentInstances
    case invalidFolderCapture(String)
    /// A path inside the package passes through a symbolic link or names something other than a folder or file.
    case unsafePath(String)
}

/// The JSON every record is written with: sorted keys and ISO 8601 dates with milliseconds, so files are diffable
/// and the same record always has the same bytes.
enum GlossCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format(date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(string)")
            }
            return date
        }
        return decoder
    }()

    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    /// The date to the nearest millisecond. Formatting the double directly would truncate (a millisecond-rounded
    /// `.123` is stored as `.12299…` and would print `.122`), so the milliseconds are written from an integer.
    static func format(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000
        let fraction = milliseconds - seconds * 1000
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(withoutFraction)
        return String(whole.dropLast()) + String(format: ".%03lldZ", fraction)
    }

    /// Parses either form and lands on the same double `NoteStore` rounds to, so a date survives a round trip.
    static func parse(_ string: String) -> Date? {
        guard let date = (try? withFraction.parse(string)) ?? (try? withoutFraction.parse(string)) else { return nil }
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// Decodes a record and keeps the JSON it came from, so a rewrite can write back what this Gloss doesn't know.
    static func decode<T: GlossRecord>(_ type: T.Type, from data: Data) throws -> T {
        var value = try decoder.decode(T.self, from: data)
        value.original = GlossOriginal(try decoder.decode(JSONValue.self, from: data))
        return value
    }

    /// Encodes a record, keeping every field of the JSON it was read from that this Gloss doesn't know, at any depth.
    static func encode<T: GlossRecord>(_ value: T) throws -> Data {
        let data = try encoder.encode(value)
        guard let old = value.original.json else { return data }
        let new = try decoder.decode(JSONValue.self, from: data)
        return try encoder.encode(T.finish(original: old, encoded: overlay(old, on: new, at: "", known: T.knownPaths)))
    }

    /// `new` plus the keys of `old` that aren't known paths. Recurses into objects whose children are known paths;
    /// anything else known is replaced whole, so a field this Gloss cleared stays cleared.
    static func overlay(_ old: JSONValue, on new: JSONValue, at path: String, known: Set<String>) -> JSONValue {
        guard case .object(let oldObject) = old, case .object(var newObject) = new else { return new }
        for (key, oldValue) in oldObject {
            let keyPath = path.isEmpty ? key : path + "." + key
            if let newValue = newObject[key] {
                if known.contains(where: { $0.hasPrefix(keyPath + ".") }) {
                    newObject[key] = overlay(oldValue, on: newValue, at: keyPath, known: known)
                }
            } else if !known.contains(keyPath) {
                newObject[key] = oldValue
            }
        }
        return .object(newObject)
    }
}

/// The JSON a record was read from. Never part of a record's equality.
public struct GlossOriginal: Hashable, Sendable {
    public var json: JSONValue?

    public init(_ json: JSONValue? = nil) { self.json = json }

    public static func == (lhs: GlossOriginal, rhs: GlossOriginal) -> Bool { true }
    public func hash(into hasher: inout Hasher) {}
}

/// A record stored as one JSON file in a package. A rewrite keeps the fields a newer Gloss wrote, at any depth.
public protocol GlossRecord: Codable, Sendable {
    var original: GlossOriginal { get set }
    /// Every key this Gloss reads, dotted for nested objects (`current.hash`); everything else is written back.
    static var knownPaths: Set<String> { get }
    /// A last pass over the JSON being written, given the JSON it was read from.
    static func finish(original: JSONValue, encoded: JSONValue) -> JSONValue
}

extension GlossRecord {
    public static func finish(original: JSONValue, encoded: JSONValue) -> JSONValue { encoded }
}

/// Where a file sits in a package, worked out from its path alone.
public enum GlossPath: Hashable, Sendable {
    case info
    /// `content/<sha256>[.<ext>]`: a snapshot named by the hash of its bytes.
    case content(hash: String)
    /// A file inside a folder capture, `content/<sha256>/…`; the folder is named by the hash of its manifest.
    case contentMember(hash: String)
    case iteration(Int)
    case author(AuthorID)
    case note(AuthorID, NoteID)
    case message(AuthorID, MessageID)
    case event(AuthorID, EventID)
    /// `authors/<id>/attachments/<sha256>.<ext>`.
    case attachment(AuthorID, hash: String)
    /// Anything else, kept as it is (a newer Gloss may write files this one doesn't know).
    case other

    public init(relativePath: String) {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1 where parts[0] == GlossFormat.infoFile:
            self = .info
        case 2 where parts[0] == GlossFormat.contentFolder:
            self = Self.hash(inFileName: parts[1]).map { .content(hash: $0) } ?? .other
        case 3... where parts[0] == GlossFormat.contentFolder:
            self = Self.isHash(parts[1]) ? .contentMember(hash: parts[1]) : .other
        case 2 where parts[0] == GlossFormat.iterationsFolder:
            if parts[1].hasSuffix(".json"), let number = Int(parts[1].dropLast(5)), number >= 0, String(number) + ".json" == parts[1] {
                self = .iteration(number)
            } else {
                self = .other
            }
        case 3 where parts[0] == GlossFormat.authorsFolder && parts[2] == GlossFormat.authorFile:
            self = Self.canonical(parts[1], as: AuthorID.self).map { .author($0) } ?? .other
        case 4 where parts[0] == GlossFormat.authorsFolder:
            guard let author = Self.canonical(parts[1], as: AuthorID.self) else { self = .other; return }
            let name = parts[3]
            let stem = name.hasSuffix(".json") ? String(name.dropLast(5)) : nil
            switch parts[2] {
            case GlossFormat.notesFolder: self = stem.flatMap { Self.canonical($0, as: NoteID.self) }.map { .note(author, $0) } ?? .other
            case GlossFormat.messagesFolder: self = stem.flatMap { Self.canonical($0, as: MessageID.self) }.map { .message(author, $0) } ?? .other
            case GlossFormat.eventsFolder: self = stem.flatMap { Self.canonical($0, as: EventID.self) }.map { .event(author, $0) } ?? .other
            case GlossFormat.attachmentsFolder: self = Self.hash(inFileName: name).map { .attachment(author, hash: $0) } ?? .other
            default: self = .other
            }
        default:
            self = .other
        }
    }

    /// An identifier only in its canonical spelling (uppercase, no Crockford aliases), so two names that a
    /// case-insensitive volume would treat as one file can't both be valid.
    static func canonical<T: PrefixedIdentifier>(_ string: String, as type: T.Type) -> T? {
        guard let id = T(validating: string), let value = ULID.decode(String(string.dropFirst(T.prefix.count))),
              T.prefix + ULID.encode(value) == string else { return nil }
        return id
    }

    /// True for a lowercase hex SHA-256.
    static func isHash(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func hash(inFileName name: String) -> String? {
        let stem = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        return isHash(stem) ? stem : nil
    }
}

/// The relative path of each kind of file in a package.
public enum GlossLayout {
    public static func content(hash: String, ext: String?) -> String {
        GlossFormat.contentFolder + "/" + fileName(hash: hash, ext: ext)
    }

    public static func iteration(_ number: Int) -> String {
        GlossFormat.iterationsFolder + "/\(number).json"
    }

    public static func authorFolder(_ author: AuthorID) -> String {
        GlossFormat.authorsFolder + "/" + author.rawValue
    }

    public static func author(_ author: AuthorID) -> String {
        authorFolder(author) + "/" + GlossFormat.authorFile
    }

    public static func note(_ id: NoteID, by author: AuthorID) -> String {
        authorFolder(author) + "/" + GlossFormat.notesFolder + "/" + id.rawValue + ".json"
    }

    public static func message(_ id: MessageID, by author: AuthorID) -> String {
        authorFolder(author) + "/" + GlossFormat.messagesFolder + "/" + id.rawValue + ".json"
    }

    public static func event(_ id: EventID, by author: AuthorID) -> String {
        authorFolder(author) + "/" + GlossFormat.eventsFolder + "/" + id.rawValue + ".json"
    }

    public static func attachment(hash: String, ext: String?, by author: AuthorID) -> String {
        authorFolder(author) + "/" + GlossFormat.attachmentsFolder + "/" + fileName(hash: hash, ext: ext)
    }

    static func fileName(hash: String, ext: String?) -> String {
        guard let ext, !ext.isEmpty else { return hash }
        return hash + "." + ext
    }
}
