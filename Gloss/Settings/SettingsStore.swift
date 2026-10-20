import Core
import Foundation
import Observation
import OSLog
import Viewers

/// Settings › Notes › When starting an iteration with open notes.
enum IterationOpenNotes: String, CaseIterable, Identifiable {
    case ask, carry, leave
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "Ask Each Time"
        case .carry: "Bring Them Along"
        case .leave: "Leave Them Behind"
        }
    }
}

/// Typed preferences backed by the `setting` table, cached in memory for the UI.
@MainActor
@Observable
final class SettingsStore {
    private let noteStore: NoteStore

    var yourName = "" { didSet { persist("collaboration.name", yourName) } }
    private(set) var authorID = AuthorID.new()
    var collaborationIdentity: GlossIdentity { GlossIdentity(author: authorID, name: yourName) }

    var launchRestore = LaunchRestore.system { didSet { persist("general.restore", launchRestore.rawValue) } }
    /// The Dock icon while Gloss runs (`AppIconStyle`); the light one while it matches the Mac's appearance.
    var appIcon = AppIconStyle.bundled {
        didSet {
            persist("general.appIcon", appIcon.rawValue)
            if appIcon != oldValue { applyAppIcon() }
        }
    }
    /// The Dock icon in dark mode, while the icon matches the Mac's appearance.
    var appIconDark = AppIconStyle.bundled {
        didSet {
            hasDarkIcon = true
            persist("general.appIconDark", appIconDark.rawValue)
            if appIconDark != oldValue { applyAppIcon() }
        }
    }
    /// Switches the Dock icon between `appIcon` and `appIconDark` as the Mac changes appearance.
    var appIconMatchesAppearance = false {
        didSet {
            persist("general.appIcon.matchAppearance", appIconMatchesAppearance ? "1" : "0")
            guard appIconMatchesAppearance != oldValue else { return }
            if appIconMatchesAppearance, loaded, !hasDarkIcon {
                // The first time: Frost for light and Graphite for dark, in the color already chosen.
                let pair = appIcon.seededPair
                appIcon = pair.light
                appIconDark = pair.dark
            }
            applyAppIcon()
        }
    }
    /// Whether a dark icon was ever chosen (or stored), so turning matching on again keeps it.
    @ObservationIgnored private var hasDarkIcon = false
    @ObservationIgnored private lazy var appearance = AppIconAppearance { [weak self] in self?.applyAppIcon() }
    var showDotfilesByDefault = false { didSet { persist("general.showDotfiles", showDotfilesByDefault ? "1" : "0") } }
    var showsQuestionsOnDock = true {
        didSet {
            persist("general.dockQuestions", showsQuestionsOnDock ? "1" : "0")
            onDockSettingChange()
        }
    }
    @ObservationIgnored var onDockSettingChange: () -> Void = {}
    var codeThemeLight = "gloss" { didSet { persist("codeTheme.light",codeThemeLight); onCodeThemeChange() } }
    var codeThemeDark = "gloss" { didSet { persist("codeTheme.dark",codeThemeDark); onCodeThemeChange() } }
    var codeThemeLightName: String? { didSet { if let name = codeThemeLightName { persist("codeTheme.lightName",name) } } }
    var codeThemeDarkName: String? { didSet { if let name = codeThemeDarkName { persist("codeTheme.darkName",name) } } }
    @ObservationIgnored var onCodeThemeChange: () -> Void = {}
    var editorFontSize: Double = 12.5 {
        didSet {
            Theme.editorFontSize = editorFontSize
            persist("editor.fontSize", String(editorFontSize))
        }
    }
    var wrapLines = true {
        didSet {
            Theme.wrapsLines = wrapLines
            persist("editor.wrap", wrapLines ? "1" : "0")
        }
    }
    var showIndentGuides = true {
        didSet {
            Theme.showsIndentGuides = showIndentGuides
            persist("editor.guides", showIndentGuides ? "1" : "0")
        }
    }
    var showMinimap = true {
        didSet {
            Theme.showsMinimap = showMinimap
            persist("editor.minimap", showMinimap ? "1" : "0")
        }
    }
    var markdownTextSize: Double = 14 {
        didSet {
            Theme.readingFontSize = markdownTextSize
            persist("markdown.textSize", String(markdownTextSize))
        }
    }
    var stagedFileExpiryDays = 7 {
        didSet {
            onStagedExpiryChange(stagedFileExpiryDays)
            persist("attachments.expiryDays", String(stagedFileExpiryDays))
        }
    }
    /// Sends started after a change use the new expiry at once, not after a relaunch.
    @ObservationIgnored var onStagedExpiryChange: (Int) -> Void = { _ in }
    /// Days a deleted note stays in Recently Deleted before it goes for good; 0 keeps it until it is emptied (issue #15).
    var trashRetentionDays = 30 {
        didSet {
            persist("notes.trashDays", String(trashRetentionDays))
            if loaded, trashRetentionDays != oldValue { onTrashRetentionChange() }
        }
    }
    /// A shorter retention deletes what is now past it at once, not at the next daily purge.
    @ObservationIgnored var onTrashRetentionChange: () -> Void = {}
    static let trashRetentionChoices = [7, 30, 90, 0]
    /// What starting an iteration does with notes still open (issue #18): ask each time, or the remembered choice.
    var iterationOpenNotes = IterationOpenNotes.ask { didSet { persist("iterations.openNotes", iterationOpenNotes.rawValue) } }
    /// Starts an iteration when the last open note resolves and the document changed since the round began.
    var iteratesAfterResolved = true { didSet { persist("iterations.afterResolved", iteratesAfterResolved ? "1" : "0") } }
    /// Sends ask to review what the agent did: resolved notes wait for the user to accept them (Review When Done).
    var reviewsResults = false { didSet { persist("notes.review", reviewsResults ? "1" : "0") } }
    /// Starts an iteration when a local file's git commit changed, checked when it opens or reloads.
    var iteratesOnCommit = false { didSet { persist("iterations.onCommit", iteratesOnCommit ? "1" : "0") } }
    /// Settings › General › Layout (2026-10-11): when the window takes the compact layout.
    var layoutMode = LayoutMode.automatic { didSet { persist("layout.mode", layoutMode.rawValue) } }
    /// The window width below which Automatic goes compact.
    var compactBelow: Double = 1000 { didSet { persist("layout.compactBelow", String(compactBelow)) } }
    static let compactBelowRange: ClosedRange<Double> = 800...1400
    /// In the compact layout the notes start as the tray's one-line bar (false) or open (true).
    var compactNotesExpanded = false { didSet { persist("layout.notesExpanded", compactNotesExpanded ? "1" : "0") } }
    /// In the compact layout the explorer slides away once a file is opened from it.
    var compactExplorerClosesOnOpen = true { didSet { persist("layout.explorerCloses", compactExplorerClosesOnOpen ? "1" : "0") } }
    /// The compact tray's height when open, as the user last dragged it.
    var compactTrayHeight: Double = 320 { didSet { persist("layout.trayHeight", String(compactTrayHeight)) } }
    /// How many ended iterations of a document keep their snapshot; 0 keeps them all.
    var snapshotsKept = 10 { didSet { persist("iterations.snapshotsKept", String(snapshotsKept)) } }
    static let snapshotsKeptChoices = [10, 0]
    /// A port outside `mcpPortRange` (a typo of 70000, a negative) is refused and the old one kept: past 65535 the
    /// listener could not even be asked for it, and a saved one would be tried at every launch.
    var mcpPort = 47831 {
        didSet {
            guard Self.mcpPortRange.contains(mcpPort) else {
                mcpPort = oldValue
                return
            }
            persist("mcp.port", String(mcpPort))
        }
    }
    /// The font size slider's range, and the attachment expiry stepper's.
    static let editorFontSizeRange: ClosedRange<Double> = 9...20
    static let markdownTextSizeRange: ClosedRange<Double> = 12...20
    static let stagedExpiryRange = 1...90
    /// Ports an unprivileged server may take; 0 would ask for any port, which agents registered on this one can't find.
    static let mcpPortRange = 1024...65535
    private(set) var loaded = false

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    func load() async {
        func read(_ key: String) async -> String? { try? await noteStore.setting(key) }
        if let value = await read("general.restore"), let restore = LaunchRestore(rawValue: value) {
            launchRestore = restore
        } else if await read("general.openLastRoot") == "0" {
            // Before #9 a toggle turned reopening off; keep it off.
            launchRestore = .nothing
        }
        if let value = await read("general.appIcon"), let style = AppIconStyle(rawValue: value) { appIcon = style }
        if let value = await read("general.appIconDark"), let style = AppIconStyle(rawValue: value) { appIconDark = style }
        if let value = await read("general.appIcon.matchAppearance") { appIconMatchesAppearance = value == "1" }
        if let value = await read("general.showDotfiles") { showDotfilesByDefault = value == "1" }
        if let value = await read("general.dockQuestions") { showsQuestionsOnDock = value == "1" }
        // Kept to what the controls offer: a value from elsewhere (an older build, a hand edit) is brought in range.
        if let value = await read("editor.fontSize"), let size = Double(value), size.isFinite { editorFontSize = min(max(size, Self.editorFontSizeRange.lowerBound), Self.editorFontSizeRange.upperBound) }
        if let value = await read("editor.wrap") { wrapLines = value == "1" }
        if let value = await read("editor.guides") { showIndentGuides = value == "1" }
        if let value = await read("editor.minimap") { showMinimap = value == "1" }
        if let value = await read("markdown.textSize"), let size = Double(value), size.isFinite { markdownTextSize = min(max(size, Self.markdownTextSizeRange.lowerBound), Self.markdownTextSizeRange.upperBound) }
        if let value = await read("attachments.expiryDays"), let days = Int(value) { stagedFileExpiryDays = min(max(days, Self.stagedExpiryRange.lowerBound), Self.stagedExpiryRange.upperBound) }
        if let value = await read("notes.trashDays"), let days = Int(value), Self.trashRetentionChoices.contains(days) { trashRetentionDays = days }
        if let value = await read("iterations.openNotes"), let choice = IterationOpenNotes(rawValue: value) { iterationOpenNotes = choice }
        if let value = await read("iterations.afterResolved") { iteratesAfterResolved = value == "1" }
        if let value = await read("notes.review") { reviewsResults = value == "1" }
        if let value = await read("iterations.onCommit") { iteratesOnCommit = value == "1" }
        if let value = await read("iterations.snapshotsKept"), let count = Int(value), Self.snapshotsKeptChoices.contains(count) { snapshotsKept = count }
        if let value = await read("layout.mode"), let mode = LayoutMode(rawValue: value) { layoutMode = mode }
        if let value = await read("layout.compactBelow"), let width = Double(value), width.isFinite { compactBelow = min(max(width, Self.compactBelowRange.lowerBound), Self.compactBelowRange.upperBound) }
        if let value = await read("layout.notesExpanded") { compactNotesExpanded = value == "1" }
        if let value = await read("layout.explorerCloses") { compactExplorerClosesOnOpen = value == "1" }
        if let value = await read("layout.trayHeight"), let height = Double(value), height.isFinite { compactTrayHeight = max(160, height) }
        if let value = await read("mcp.port"), let port = Int(value), Self.mcpPortRange.contains(port) { mcpPort = port }
        codeThemeLightName = await read("codeTheme.lightName")
        codeThemeDarkName = await read("codeTheme.darkName")
        codeThemeLight = await read("codeTheme.light") ?? "gloss"
        codeThemeDark = await read("codeTheme.dark") ?? "gloss"
        yourName = await read("collaboration.name") ?? ""
        if let id = try? await noteStore.collaborationAuthorID() { authorID = id }
        loaded = true
    }

    /// Shows the icon for the Mac's appearance now, and watches for changes while it matches.
    private func applyAppIcon() {
        appearance.isWatching = appIconMatchesAppearance
        AppIconStyle.style(light: appIcon, dark: appIconDark, matching: appIconMatchesAppearance, isDark: AppIconAppearance.isDark)
            .apply(drawn: appIconMatchesAppearance)
    }

    /// The last setting written; each write waits for the one before, so two quick changes to a setting land in the
    /// order they were made (unordered, turning matching off and on again could leave the older value stored).
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    private func persist(_ key: String, _ value: String) {
        guard loaded else { return }
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            do { try await noteStore.setSetting(key, value) } catch { Log.app.error("setting \(key, privacy: .public) failed: \(error, privacy: .public)") }
        }
    }

    /// Size of the attachment cache on disk.
    nonisolated static func attachmentCacheSize() -> Int64 {
        folderSize(AttachmentCache.root)
    }

    nonisolated static func folderSize(_ folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    nonisolated static func clearAttachmentCache() {
        try? FileManager.default.removeItem(at: AttachmentCache.root)
    }
}
