import Testing
@testable import Gloss

struct PathDisambiguatorTests {
    @Test func onlyCollidingNamesGetTheShortestDistinctPlace() {
        let places = PathDisambiguator.places(for: [
            "/Users/c/app/docs/PRODUCT.md",
            "/Users/c/web/docs/PRODUCT.md",
            "/Users/c/app/PRODUCT.md",
            "/Users/c/app/CLAUDE.md",
        ])
        #expect(places["/Users/c/app/CLAUDE.md"] == nil)
        #expect(places["/Users/c/app/docs/PRODUCT.md"] == "…/app/docs")
        #expect(places["/Users/c/web/docs/PRODUCT.md"] == "…/web/docs")
        #expect(places["/Users/c/app/PRODUCT.md"] == "…/c/app")
    }

    @Test func oneFolderIsEnoughWhenParentsDiffer() {
        let places = PathDisambiguator.places(for: ["/p/a/README.md", "/p/b/README.md", "/p/a/README.md"])
        #expect(places == ["/p/a/README.md": "…/a", "/p/b/README.md": "…/b"])
    }
}
