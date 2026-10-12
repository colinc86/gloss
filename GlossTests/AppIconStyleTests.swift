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

    @Test func matchingPicksTheLightOrDarkIcon() {
        #expect(AppIconStyle.style(light: .frostYellow, dark: .graphiteOrange, matching: true, isDark: true) == .graphiteOrange)
        #expect(AppIconStyle.style(light: .frostYellow, dark: .graphiteOrange, matching: true, isDark: false) == .frostYellow)
        #expect(AppIconStyle.style(light: .frostYellow, dark: .graphiteOrange, matching: false, isDark: true) == .frostYellow)
        #expect(AppIconStyle.style(light: .frostYellow, dark: .graphiteOrange, matching: false, isDark: false) == .frostYellow)
        #expect(AppIconStyle.bundled.dockImage(drawn: true) != nil, "while matching, Graphite Yellow is drawn as shown")
    }

    @Test func matchingStartsFromFrostForLightAndGraphiteForDark() {
        #expect(AppIconStyle.graphiteBlue.seededPair == (light: .frostBlue, dark: .graphiteBlue))
        #expect(AppIconStyle.frostPink.seededPair == (light: .frostPink, dark: .graphitePink))
        #expect(AppIconStyle.pixel.seededPair == (light: .pixel, dark: .pixel))
    }

    @Test func theLightAndDarkChoicesAreRemembered() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let settings = SettingsStore(noteStore: store)
        await settings.load()
        defer { AppIconStyle.bundled.apply() }
        settings.appIconMatchesAppearance = true
        #expect(settings.appIcon == .frostYellow && settings.appIconDark == .graphiteYellow, "seeded from Graphite Yellow")
        settings.appIconDark = .graphiteOrange
        settings.appIconMatchesAppearance = false
        settings.appIconMatchesAppearance = true
        #expect(settings.appIconDark == .graphiteOrange, "turning it on again keeps the dark choice")
        for _ in 0..<200 where (try? await store.setting("general.appIconDark")) != "graphite-orange" { try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<200 where (try? await store.setting("general.appIcon.matchAppearance")) != "1" { try await Task.sleep(for: .milliseconds(20)) }
        let reloaded = SettingsStore(noteStore: store)
        await reloaded.load()
        #expect(reloaded.appIconMatchesAppearance && reloaded.appIcon == .frostYellow && reloaded.appIconDark == .graphiteOrange)
        reloaded.appIconMatchesAppearance = false
    }
}
