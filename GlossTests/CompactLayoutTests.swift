import Core
import Foundation
import Testing
@testable import Gloss

/// The compact layout (2026-10-11): when the window takes it, and the tray's steps.
@MainActor
struct CompactLayoutTests {
    @Test func automaticGoesCompactBelowTheThresholdAndBackPastIt() {
        func compact(_ width: Double, was: Bool) -> Bool {
            LayoutModel.compact(mode: .automatic, width: width, threshold: 1000, wasCompact: was)
        }
        #expect(!compact(1200, was: false))
        #expect(compact(980, was: false))
        #expect(compact(1020, was: true), "within the hysteresis it stays compact")
        #expect(!compact(1041, was: true))
        #expect(compact(0, was: true) && !compact(0, was: false), "an unmeasured window keeps what it had")
        #expect(LayoutModel.compact(mode: .compact, width: 2000, threshold: 1000, wasCompact: false))
        #expect(!LayoutModel.compact(mode: .full, width: 500, threshold: 1000, wasCompact: true))
    }

    @Test func goingCompactStartsTheTrayAsSettingsSaysAndGoingBackRestoresThePanel() {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        model.showNotesPanel = true
        model.settings.compactNotesExpanded = false
        model.updateLayout(width: 1400)
        #expect(!model.layout.isCompact)
        model.updateLayout(width: 900)
        #expect(model.layout.isCompact && !model.showNotesPanel, "the tray starts as a bar")
        model.layout.isExplorerShown = true
        model.updateLayout(width: 1300)
        #expect(!model.layout.isCompact && model.showNotesPanel, "the side panel comes back as it was")
        #expect(!model.layout.isExplorerShown)
        model.settings.layoutMode = .compact
        model.updateLayout()
        #expect(model.layout.isCompact, "Always Compact at any width")
    }

    @Test func theTrayStepsWrap() {
        #expect(NotesTray.stepped(count: 3, from: nil, by: 1) == 0)
        #expect(NotesTray.stepped(count: 3, from: nil, by: -1) == 2)
        #expect(NotesTray.stepped(count: 3, from: 2, by: 1) == 0)
        #expect(NotesTray.stepped(count: 3, from: 0, by: -1) == 2)
        #expect(NotesTray.stepped(count: 0, from: nil, by: 1) == nil)
    }

    @Test func layoutSettingsAreRemembered() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let settings = SettingsStore(noteStore: store)
        await settings.load()
        settings.layoutMode = .full
        settings.compactBelow = 1150
        settings.compactNotesExpanded = true
        settings.compactExplorerClosesOnOpen = false
        for _ in 0..<200 where (try? await store.setting("layout.explorerCloses")) != "0" { try await Task.sleep(for: .milliseconds(20)) }
        let reloaded = SettingsStore(noteStore: store)
        await reloaded.load()
        #expect(reloaded.layoutMode == .full && reloaded.compactBelow == 1150 && reloaded.compactNotesExpanded && !reloaded.compactExplorerClosesOnOpen)
    }
}
