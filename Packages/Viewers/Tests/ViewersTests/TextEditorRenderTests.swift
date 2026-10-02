import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

struct TextEditorRenderTests {
    func render(languageName: String?) throws -> (distinctColors: Int, textView: SourceTextView) {
        let source = "import Foundation\n\nfunc greet() -> String {\n    return \"hi\" // note\n}\n"
        let controller = TextEditorController(text: source, languageName: languageName)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        window.contentView = hosting
        window.layoutIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        var colors: Set<String> = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: min(rep.pixelsWide, 300), by: 2) {
                if let color = rep.colorAt(x: x, y: y) { colors.insert(String(format: "%.1f,%.1f,%.1f", color.redComponent, color.greenComponent, color.blueComponent)) }
            }
        }
        return (colors.count, textView)
    }

    @Test func plainTextDrawsSomething() throws {
        let (distinct, _) = try render(languageName: nil)
        #expect(distinct > 3, "text should produce more than a flat background")
    }

    @Test func highlightedTextDrawsSomething() throws {
        let (distinct, _) = try render(languageName: "swift")
        #expect(distinct > 3, "highlighted text should produce more than a flat background")
    }
}
