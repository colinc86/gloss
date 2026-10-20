import AppKit
import Core
import Testing
import Viewers
@testable import Gloss

@MainActor
@Suite(.serialized)
struct SettingsWiringTests {
    @Test func editorSettingsReachNewEditors() throws {
        let settings = SettingsStore(noteStore: NoteStore(database: try AppDatabase.inMemory()))
        let size = Theme.fontSize
        defer {
            Theme.fontSize = size
            Theme.wrapsLines = true
            Theme.showsIndentGuides = true
        }
        settings.fontSize = 15
        settings.wrapLines = false
        settings.showIndentGuides = false
        #expect(Theme.editorFont.pointSize == 15)
        #expect(Theme.wrapsLines == false)
        #expect(Theme.showsIndentGuides == false)
    }

    @Test func stagedExpiryReachesSendsWithoutRelaunch() throws {
        let settings = SettingsStore(noteStore: NoteStore(database: try AppDatabase.inMemory()))
        var seen: Int?
        settings.onStagedExpiryChange = { seen = $0 }
        settings.stagedFileExpiryDays = 30
        #expect(seen == 30)
    }
}
