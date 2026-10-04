import Foundation
import Testing
@testable import Gloss

struct AppLaunchOptionsTests {
    @Test func defaultsWhenNoArguments() {
        let options = AppLaunchOptions(arguments: ["/path/to/app"])
        #expect(options.root == nil)
        #expect(options.host == "local")
        #expect(options.open == nil)
        #expect(options.resetDatabase == false)
    }

    @Test func aTestHostUsesAThrowawayDatabase() {
        let hosted = AppLaunchOptions(arguments: ["/app"], environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"])
        #expect(hosted.isTestHost && hosted.resetDatabase)
        let normal = AppLaunchOptions(arguments: ["/app", "--root", "/r"], environment: ["HOME": "/Users/c"])
        #expect(!normal.isTestHost && !normal.resetDatabase && normal.root == "/r")
    }

    /// This very process is a hosted test run, so the app it launched must not have touched the real state.
    @Test @MainActor func theRunningTestHostSkippedStartup() {
        #expect(AppLaunchOptions(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment).isTestHost)
    }

    @Test func appearanceTakesOnlyDarkOrLight() {
        #expect(AppLaunchOptions(arguments: ["/app", "--appearance", "Dark"]).appearance == "dark")
        #expect(AppLaunchOptions(arguments: ["/app", "--appearance=light"]).appearance == "light")
        #expect(AppLaunchOptions(arguments: ["/app", "--appearance", "sepia"]).appearance == nil)
    }

    @Test func parsesEveryOption() {
        let options = AppLaunchOptions(arguments: [
            "/app", "--root", "/Users/me/proj", "--host", "asus", "--open", "/Users/me/proj/README.md", "--reset-db",
        ])
        #expect(options.root == "/Users/me/proj")
        #expect(options.host == "asus")
        #expect(options.open == "/Users/me/proj/README.md")
        #expect(options.resetDatabase)
    }

    @Test func ignoresXcodeArgumentsAndAcceptsEqualsForm() {
        let options = AppLaunchOptions(arguments: [
            "/app", "-NSDocumentRevisionsDebugMode", "YES", "--root=/tmp/with space", "-ApplePersistenceIgnoreState", "YES",
        ])
        #expect(options.root == "/tmp/with space")
        #expect(options.host == "local")
    }

    @Test func missingValueDoesNotCrash() {
        let options = AppLaunchOptions(arguments: ["/app", "--root"])
        #expect(options.root == nil)
    }
}
