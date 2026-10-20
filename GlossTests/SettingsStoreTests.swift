import Core
import Foundation
import Testing
@testable import Gloss

@MainActor
struct SettingsStoreTests {
    /// A port the server can't listen on is refused as it is typed, and one saved by an older build is not loaded:
    /// past 65535 the listener trapped, at every launch.
    @Test func anMCPPortOutOfRangeIsRefused() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let settings = SettingsStore(noteStore: store)
        await settings.load()
        settings.mcpPort = 48_000
        #expect(settings.mcpPort == 48_000)
        settings.mcpPort = 70_000
        #expect(settings.mcpPort == 48_000, "the last good port stays")
        settings.mcpPort = 0
        #expect(settings.mcpPort == 48_000)
        settings.mcpPort = 80
        #expect(settings.mcpPort == 48_000, "a privileged port is refused too")

        // The good port is saved in the background; let it land before writing an older build's bad one over it.
        for _ in 0..<100 where try await store.setting("mcp.port") != "48000" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await store.setting("mcp.port") == "48000", "only the good port was saved")
        try await store.setSetting("mcp.port", "70000")
        let fresh = SettingsStore(noteStore: store)
        await fresh.load()
        #expect(fresh.mcpPort == 47_831, "a saved port out of range falls back to the default")
    }

    /// A font size or expiry saved outside what the controls offer is brought into their range when loaded.
    @Test func savedValuesOutOfRangeAreBroughtIn() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        try await store.setSetting("editor.fontSize", "300")
        try await store.setSetting("attachments.expiryDays", "0")
        let settings = SettingsStore(noteStore: store)
        await settings.load()
        #expect(settings.fontSize == SettingsStore.fontSizeRange.upperBound)
        #expect(settings.stagedFileExpiryDays == 1)
    }
}


extension SettingsStoreTests {
    @Test func syntaxThemeIdsDefaultToGlossAndPersistIndependently() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let settings = SettingsStore(noteStore: store); await settings.load()
        #expect(settings.codeThemeLight == "gloss" && settings.codeThemeDark == "gloss")
        settings.codeThemeLight = "fixture-light"; settings.codeThemeDark = "fixture-dark"
        for _ in 0..<100 where try await store.setting("codeTheme.dark") != "fixture-dark" { try await Task.sleep(for: .milliseconds(10)) }
        let fresh = SettingsStore(noteStore: store); await fresh.load()
        #expect(fresh.codeThemeLight == "fixture-light" && fresh.codeThemeDark == "fixture-dark")
    }
}
