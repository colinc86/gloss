import AppKit
import SwiftUI

/// Help › Acknowledgments: the licenses of the packages Gloss is built on and of its theme palettes, from the bundled
/// `Acknowledgments.txt` that `scripts/acknowledgments.py` writes.
struct AcknowledgmentsWindow: View {
    static let text: String = {
        guard let url = Bundle.main.url(forResource: "Acknowledgments", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "The acknowledgments couldn't be loaded." }
        return text
    }()

    var body: some View {
        AcknowledgmentsText(text: Self.text)
            .frame(minWidth: 560, idealWidth: 640, minHeight: 400, idealHeight: 640)
    }
}

/// A read-only, selectable text view: a few thousand lines of license text are more than a SwiftUI `Text` scrolls well.
private struct AcknowledgmentsText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.string = text
        textView.setAccessibilityLabel("Acknowledgments")
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
