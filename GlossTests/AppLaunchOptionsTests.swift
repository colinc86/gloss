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
