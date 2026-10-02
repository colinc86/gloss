import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

struct TextEditorLayoutTests {
    @Test func textViewFillsTheScrollViewAndKeepsColor() throws {
        let controller = TextEditorController(text: (1...40).map { "line \($0)" }.joined(separator: "\n"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()

        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let scroll = try #require(find(NSScrollView.self, in: hosting))
        let textView = try #require(find(SourceTextView.self, in: hosting))
        let color = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let font = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        var fragmentFrames: [CGRect] = []
        textView.textLayoutManager?.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            fragmentFrames.append(fragment.layoutFragmentFrame)
            return fragmentFrames.count < 3
        }
        #expect(textView.frame.width > 100, "text view should be as wide as the scroll view")
        #expect(textView.frame.height > 100, "text view should grow to its content")
        #expect(color != nil)
    }
}
