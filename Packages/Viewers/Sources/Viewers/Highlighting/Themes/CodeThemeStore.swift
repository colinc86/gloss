import CoreServices
import Foundation
import Observation

/// A theme file that didn't load, shown quietly in Settings.
public nonisolated struct ThemeProblem: Hashable, Sendable {
    public let fileName: String
    public let message: String
}

/// The themes on offer: the built-ins (read-only) and the user's, one JSON file each in the themes folder, which is
/// watched so a file added or changed outside the app shows up.
@Observable public final class CodeThemeStore {
    public static var defaultFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Gloss/Themes", directoryHint: .isDirectory)
    }

    public let folder: URL
    /// Built-ins first (Gloss, then presets by name), then the user's themes by name.
    public private(set) var themes: [CodeTheme] = CodeTheme.builtIns
    public private(set) var problems: [ThemeProblem] = []

    @ObservationIgnored private var eventStream: FSEventStreamRef?
    @ObservationIgnored private let watchTarget = WatchTarget()
    @ObservationIgnored private var reloadPending = false

    public init(folder: URL = CodeThemeStore.defaultFolder, watches: Bool = true) {
        self.folder = folder
        reload()
        if watches { startWatching() }
    }

    isolated deinit {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
    }

    public func theme(id: String) -> CodeTheme? {
        themes.first { $0.id == id }
    }

    /// The theme to draw with for a saved id: the theme, or Gloss and a sentence to show when it's missing or broken.
    /// A nil id (nothing chosen yet) is Gloss without a problem.
    public func resolve(id: String?) -> (theme: CodeTheme, problem: String?) {
        guard let id, id != CodeTheme.gloss.id else { return (.gloss, nil) }
        if let theme = theme(id: id) { return (theme, nil) }
        if let problem = problems.first(where: { $0.fileName == "\(id).json" }) {
            return (.gloss, "The theme “\(id)” can’t be read, so Gloss is used instead. \(problem.message)")
        }
        return (.gloss, "The theme “\(id)” is missing, so Gloss is used instead.")
    }

    /// Writes a user theme to `<id>.json`, replacing any earlier version.
    public func save(_ theme: CodeTheme) throws {
        guard !theme.isBuiltIn else { throw CodeThemeError.readOnly(theme.name) }
        guard CodeTheme.isValidIdentifier(theme.id) else { throw CodeThemeError.invalidIdentifier(theme.id) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = theme
        saved.formatVersion = CodeTheme.formatVersion
        try saved.encoded().write(to: url(for: theme.id), options: .atomic)
        reload()
    }

    /// Moves a user theme's file to the Trash, so a mistaken delete can be undone in Finder. Returns where it went
    /// (nil when there was no file).
    @discardableResult
    public func delete(id: String) throws -> URL? {
        if let builtIn = CodeTheme.builtIns.first(where: { $0.id == id }) { throw CodeThemeError.readOnly(builtIn.name) }
        guard CodeTheme.isValidIdentifier(id) else { throw CodeThemeError.invalidIdentifier(id) }
        let file = url(for: id)
        var trashed: NSURL?
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
        }
        reload()
        return trashed as URL?
    }

    /// A saved, editable copy under a new id: "<name> Copy" unless a name is given.
    @discardableResult
    public func duplicate(_ theme: CodeTheme, name: String? = nil) throws -> CodeTheme {
        var copy = theme
        copy.name = uniqueName(name ?? "\(theme.name) Copy")
        copy.id = CodeTheme.identifier(forName: copy.name, avoiding: takenIDs)
        try save(copy)
        return copy
    }

    /// Reads a theme in any format `CodeThemeImporter` knows and saves it under a fresh id and name.
    public func importTheme(from url: URL) throws -> CodeThemeImport {
        let data = try Self.readCapped(url)
        var result = try CodeThemeImporter.parse(data, fileName: url.lastPathComponent)
        result.theme.name = uniqueName(result.theme.name)
        result.theme.id = CodeTheme.identifier(forName: result.theme.name, avoiding: takenIDs)
        try save(result.theme)
        return result
    }

    public func export(_ theme: CodeTheme, to url: URL) throws {
        try theme.encoded().write(to: url, options: .atomic)
    }

    public func reload() {
        reloadPending = false
        var user: [CodeTheme] = []
        var problems: [ThemeProblem] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension.lowercased() == "json" {
            let fileName = file.lastPathComponent
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            do {
                let theme = try CodeTheme.decode(Self.readCapped(file))
                guard theme.id == file.deletingPathExtension().lastPathComponent else {
                    throw CodeThemeError.malformed("its id “\(theme.id)” doesn’t match the file name.")
                }
                guard !theme.isBuiltIn else { throw CodeThemeError.malformed("“\(theme.id)” is the id of a built-in theme.") }
                user.append(theme)
            } catch {
                problems.append(ThemeProblem(fileName: fileName, message: error.localizedDescription))
            }
        }
        user.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let themes = CodeTheme.builtIns + user
        problems.sort { $0.fileName < $1.fileName }
        if themes != self.themes { self.themes = themes }
        if problems != self.problems { self.problems = problems }
    }

    /// At most one byte over the limit, so a huge file, a device or a FIFO dressed as a theme can't stall or flood the read.
    nonisolated static func readCapped(_ url: URL) throws -> Data {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CodeThemeError.malformed("it isn’t a regular file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: CodeTheme.maximumFileSize + 1) ?? Data()
        guard data.count <= CodeTheme.maximumFileSize else { throw CodeThemeError.tooLarge(bytes: data.count) }
        return data
    }

    // MARK: Private

    private var takenIDs: Set<String> {
        var ids = Set(themes.map(\.id))
        // File names compare case-insensitively on APFS: a broken Foo.json holds "foo".
        ids.formUnion(problems.map { ($0.fileName as NSString).deletingPathExtension.lowercased() })
        return ids
    }

    private func uniqueName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled Theme" : trimmed
        let names = Set(themes.map(\.name))
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private func url(for id: String) -> URL {
        folder.appending(path: "\(id).json", directoryHint: .notDirectory)
    }

    /// One FSEvents stream on the folder with file-level events: a file added, removed, renamed or saved in place,
    /// and the folder itself going away or coming back (the stream follows the path, not a descriptor).
    private func startWatching() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watchTarget.store = self
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(watchTarget).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let target = Unmanaged<WatchTarget>.fromOpaque(info).takeUnretainedValue()
            // The stream's queue is the main queue.
            MainActor.assumeIsolated { target.store?.scheduleReload() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        eventStream = stream
    }

    /// Coalesces a burst of events (an editor's save is several) into one reload.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.reloadPending else { return }
                self.reload()
            }
        }
    }
}

/// What the FSEvents callback reaches the store through. The store owns it, so it outlives the stream, and it holds
/// the store weakly.
nonisolated private final class WatchTarget: @unchecked Sendable {
    @MainActor weak var store: CodeThemeStore?
}
