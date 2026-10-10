import Testing
@testable import Core

struct HomeAbbreviationTests {
    @Test func onlyTheWholeHomeFolderBecomesATilde() {
        #expect(PathUtilities.abbreviatingHome("/Users/me/src", home: "/Users/me") == "~/src")
        #expect(PathUtilities.abbreviatingHome("/Users/me", home: "/Users/me/") == "~")
        #expect(PathUtilities.abbreviatingHome("/Users/meg/src", home: "/Users/me") == "/Users/meg/src")
        #expect(PathUtilities.abbreviatingHome("/data/Users/me/x", home: "/Users/me") == "/data/Users/me/x", "only at the start")
        #expect(PathUtilities.abbreviatingHome("/etc", home: "/") == "/etc")
    }
}
