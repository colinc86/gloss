import Core
import Foundation
import Observation
import OSLog
import Viewers

/// Typed preferences backed by the `setting` table, cached in memory for the UI.
@MainActor
@Observable
final class SettingsStore {
    private let noteStore: NoteStore

    var launchRestore = LaunchRestore.system { didSet { persist("general.restore", launchRestore.rawValue) } }
    /// The Dock icon while Gloss runs (`AppIconStyle`).
    var appIcon = AppIconStyle.bundled {
        didSet {
            persist("general.appIcon", appIcon.rawValue)
            if appIcon != oldValue { appIcon.apply() }
        }
    }
    var showDotfilesByDefault = false { didSet { persist("general.showDotfiles", showDotfilesByDefault ? "1" : "0") } }
    var showsQuestionsOnDock = true {
        didSet {
            persist("general.dockQuestions", showsQuestionsOnDock ? "1" : "0")
            onDockSettingChange()
        }
    }
    @ObservationIgnored var onDockSettingChange: () -> Void = {}
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
    var stagedFileExpiryDays = 7 {
        didSet {
            onStagedExpiryChange(stagedFileExpiryDays)
            persist("attachments.expiryDays", String(stagedFileExpiryDays))
        }
    }
    /// Sends started after a change use the new expiry at once, not after a relaunch.
    @ObservationIgnored var onStagedExpiryChange: (Int) -> Void = { _ in }
    var mcpPort = 47831 { didSet { persist("mcp.port", String(mcpPort)) } }
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
        if let value = await read("general.showDotfiles") { showDotfilesByDefault = value == "1" }
        if let value = await read("general.dockQuestions") { showsQuestionsOnDock = value == "1" }
        if let value = await read("editor.fontSize"), let size = Double(value) { editorFontSize = size }
        if let value = await read("editor.wrap") { wrapLines = value == "1" }
        if let value = await read("editor.guides") { showIndentGuides = value == "1" }
        if let value = await read("attachments.expiryDays"), let days = Int(value) { stagedFileExpiryDays = days }
        if let value = await read("mcp.port"), let port = Int(value) { mcpPort = port }
        loaded = true
    }

    private func persist(_ key: String, _ value: String) {
        guard loaded else { return }
        Task {
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
