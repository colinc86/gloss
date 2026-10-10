import Core
import Testing
@testable import Viewers

/// A file the highlighter can color opens in the text editor, never in Quick Look or as unsupported.
struct GrammarCoverageTests {
    @Test func everyHighlightedFileOpensAsText() {
        let editable: Set<DocumentKind> = [.code, .text, .markdown]
        let byExtension = GrammarCatalog.highlightedExtensions.filter { !editable.contains(DocumentKindDetector.kind(forPath: "/p/a.\($0)")) }
        #expect(byExtension.isEmpty, "extensions colored but not opened as text: \(byExtension.sorted())")
        let byName = GrammarCatalog.highlightedFileNames.filter { !editable.contains(DocumentKindDetector.kind(forPath: "/p/\($0)")) }
        #expect(byName.isEmpty, "file names colored but not opened as text: \(byName.sorted())")
    }

    @Test func shellDotfilesAndLockfilesAreColored() {
        #expect(GrammarCatalog.languageName(forPath: "/Users/me/.zprofile") == "bash")
        #expect(GrammarCatalog.languageName(forPath: "/p/Cargo.lock") == "toml")
        #expect(GrammarCatalog.languageName(forPath: "/p/types.pyi") == "python")
        #expect(DocumentKindDetector.kind(forPath: "/p/types.pyi") == .code)
    }
}
