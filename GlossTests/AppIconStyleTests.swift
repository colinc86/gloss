import AppKit
import Core
import Testing
@testable import Gloss

/// Settings › General › App Icon: every style ships its picture, the bundled one hands the Dock back to the system,
/// and the choice is remembered.
@MainActor
struct AppIconStyleTests {
    @Test func everyStyleHasItsPictureAndAName() {
        #expect(AppIconStyle.allCases.count == 16)
        for style in AppIconStyle.allCases {
            #expect(style.thumbnail != nil, "\(style.rawValue) is in the asset catalog")
        }
        #expect(AppIconStyle.graphiteBlue.title == "Graphite Blue")
        #expect(AppIconStyle.starburst.title == "Starburst")
        #expect(Set(AppIconStyle.allCases.map(\.family)) == Set(AppIconStyle.Family.allCases))
    }

    @Test func theBundledStyleLeavesTheDockToTheSystem() throws {
        #expect(AppIconStyle.bundled.dockImage == nil, "nil restores the bundle's icon, with the Mac's icon style")
        let image = try #require(AppIconStyle.frostPink.dockImage)
        #expect(image.size == NSSize(width: 1024, height: 1024))
    }

    @Test func theChoiceIsRemembered() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let settings = SettingsStore(noteStore: store)
        await settings.load()
        #expect(settings.appIcon == .bundled)
        settings.appIcon = .pixel
        // The test host never applies an icon (start() doesn't run there), so the bundled one is what was showing.
        defer { AppIconStyle.bundled.apply() }
        for _ in 0..<200 where (try? await store.setting("general.appIcon")) != "fun-pixel" { try await Task.sleep(for: .milliseconds(20)) }
        let reloaded = SettingsStore(noteStore: store)
        await reloaded.load()
        #expect(reloaded.appIcon == .pixel)
    }
}
