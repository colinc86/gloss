import Foundation

public struct GlossMergeReport: Sendable, Hashable {
    /// Paths written into the destination.
    public var written: [String] = []
    /// Files that should have been identical but weren't (a write-once file with two contents, a snapshot whose
    /// bytes don't match its name); the merge still picked one the same way on every Mac.
    public var anomalies: [GlossIssue] = []
    public var treeHash = ""
}

/// Merges versions of one package, such as the conflict versions iCloud keeps or a duplicate `Review 2.gloss`,
/// into one. Because every file has one writer, the result is the union of all files; where two versions hold the
/// same path, the winner is chosen from the files alone, so every Mac merging the same versions gets the same tree:
/// - `Info.json`: the higher current iteration, then the later capture, then the higher `rev`.
/// - A note or `author.json`: the higher `rev`.
/// - An iteration: for the current iteration, the one whose snapshot is the winning `Info.json`'s; then an ended
///   one over an open one, then the higher `rev`.
/// - A snapshot, attachment or folder-capture member: the copy whose bytes match the hash in its name (or in its
///   folder's manifest).
/// - Anything else (messages and events are write-once): the bytes with the greatest SHA-256.
/// Nothing is ever deleted. Versions with different instance identifiers are different reviews and are refused.
public enum GlossMerge {
    public static func merge(_ versions: [URL], into destination: URL) throws -> GlossMergeReport {
        let target = GlossPackage(url: destination)
        let instance = try target.readInfo().instance
        let others = versions.filter { $0.standardizedFileURL != destination.standardizedFileURL }
        for version in others {
            guard try GlossPackage(url: version).readInfo().instance == instance else { throw GlossPackageError.differentInstances }
        }

        var candidates: [String: [URL]] = [:]
        for root in [destination] + others {
            for path in GlossPackage.files(under: root) { candidates[path, default: []].append(root) }
        }

        func contents(_ path: String) -> [Data] {
            (candidates[path] ?? []).compactMap { root in GlossPackage(url: root).readIfSafe(path) }
        }
        var report = GlossMergeReport()
        // Info.json first: the current iteration's record must agree with it.
        let infoWinner = pick(GlossFormat.infoFile, contents(GlossFormat.infoFile), current: nil, manifests: [:], &report)
        let current = infoWinner.flatMap { try? GlossCoding.decode(GlossInfo.self, from: $0) }?.current
        // Folder captures' manifests, from any version whose manifest matches its folder's name.
        var manifests: [String: [String: String]] = [:]
        for path in candidates.keys {
            guard case .contentMember(let hash) = GlossPath(relativePath: path), path.hasSuffix("/" + GlossFormat.manifestFile),
                  let data = contents(path).first(where: { $0.sha256Hex == hash }),
                  let members = try? GlossCoding.decoder.decode([String: String].self, from: data) else { continue }
            manifests[hash] = members
        }
        for path in candidates.keys.sorted() {
            let winner = path == GlossFormat.infoFile ? infoWinner : pick(path, contents(path), current: current, manifests: manifests, &report)
            guard let winner else { continue }
            let current = target.readIfSafe(path)
            if current != winner {
                try GlossPackageWriter.write(winner, to: target, path)
                report.written.append(path)
            }
        }
        report.treeHash = try target.treeHash()
        return report
    }

    /// The version of one path that wins, from its candidates' bytes.
    static func pick(_ path: String, _ contents: [Data], current: GlossCurrent?, manifests: [String: [String: String]], _ report: inout GlossMergeReport) -> Data? {
        let distinct = Array(Set(contents))
        guard distinct.count > 1 else { return distinct.first }
        switch GlossPath(relativePath: path) {
        case .info:
            let winner = best(distinct, as: GlossInfo.self) { ($0.current.iteration, GlossCoding.format($0.current.capturedAt), $0.rev) }
            // Owners only join within an instance, so an adoption on one install survives another install's write.
            let owners = distinct.compactMap { try? GlossCoding.decode(GlossInfo.self, from: $0) }.reduce(into: Set<AuthorID>()) { $0.formUnion($1.owners) }
            guard let winner, var info = try? GlossCoding.decode(GlossInfo.self, from: winner), owners != info.owners else { return winner }
            owners.forEach { info.addOwner($0) }
            return (try? GlossCoding.encode(info)) ?? winner
        case .note:
            return best(distinct, as: GlossNote.self) { (0, "", $0.rev) }
        case .author:
            return best(distinct, as: GlossAuthor.self) { (0, "", $0.rev) }
        case .iteration(let number):
            return best(distinct, as: GlossIteration.self) {
                let matchesInfo = number == current?.iteration && $0.snapshot == current?.hash
                return ((matchesInfo ? 2 : 0) + ($0.endedAt == nil ? 0 : 1), "", $0.rev)
            }
        case .content(let hash), .attachment(_, let hash):
            return matching(hash, distinct, path, &report)
        case .contentMember(let hash):
            let name = String(path.dropFirst(GlossFormat.contentFolder.count + hash.count + 2))
            if name == GlossFormat.manifestFile { return matching(hash, distinct, path, &report) }
            if let expected = manifests[hash]?[name] { return matching(expected, distinct, path, &report) }
            report.anomalies.append(GlossIssue(path: path, problem: "A folder-capture file with \(distinct.count) different contents and no manifest"))
            return byHash(distinct)
        case .message, .event, .other:
            report.anomalies.append(GlossIssue(path: path, problem: "A write-once file has \(distinct.count) different contents"))
            return byHash(distinct)
        }
    }

    /// The copy whose bytes hash to `hash`, or failing that the greatest hash.
    private static func matching(_ hash: String, _ contents: [Data], _ path: String, _ report: inout GlossMergeReport) -> Data? {
        if let match = contents.first(where: { $0.sha256Hex == hash }) {
            report.anomalies.append(GlossIssue(path: path, problem: "Another version's bytes don't match their hash"))
            return match
        }
        report.anomalies.append(GlossIssue(path: path, problem: "No version's bytes match their hash"))
        return byHash(contents)
    }

    /// The readable record with the greatest key; ties and unreadable records fall back to the greatest hash.
    private static func best<T: GlossRecord>(_ contents: [Data], as type: T.Type, key: (T) -> (Int, String, String)) -> Data? {
        let readable = contents.compactMap { data in (try? GlossCoding.decode(type, from: data)).map { (data, key($0)) } }
        guard let top = readable.map(\.1).max(by: <) else { return byHash(contents) }
        return byHash(readable.filter { $0.1 == top }.map(\.0))
    }

    private static func byHash(_ contents: [Data]) -> Data? {
        contents.max { $0.sha256Hex < $1.sha256Hex }
    }
}

/// Copies of a review. A copy is a new instance that remembers its origin and never rejoins the live review; the
/// local index keys reviews by instance, so the live review and its copies stay apart even with the same review id.
extension GlossPackage {
    /// Send a Copy: the whole package at `destination` with a new instance and an origin reference. The review id,
    /// owner and history stay, so the copy reads as the review did; nobody delivers from it as the owner.
    @discardableResult
    public func makeCopy(to destination: URL, at date: Date = Date()) throws -> GlossInfo {
        var info = try readInfo()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw GlossPackageError.alreadyExists(destination.path) }
        let staging = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(ULID.generate())", directoryHint: .isDirectory)
        do {
            try FileManager.default.copyItem(at: url, to: staging)
            info.origin = GlossOrigin(review: info.id, instance: info.instance, iteration: info.current.iteration, copiedAt: date)
            info.instance = .new()
            info.rev = ULID.generate()
            try GlossPackageWriter.write(GlossCoding.encode(info), to: GlossPackage(url: staging), GlossFormat.infoFile)
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return info
    }
}
