import Foundation

/// The lines a review card shows for an anchor: the selected text, marked, with the context lines the anchor keeps
/// either side. Built from the anchor alone, so it works for closed documents and for the anchor as it was sent.
public struct ReviewExcerpt: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// 1-based line in the file; nil for anchors without stable lines (web elements).
        public var number: Int?
        public var text: String
        /// Part of the selection, rather than context around it.
        public var selected: Bool

        public init(number: Int?, text: String, selected: Bool) {
            self.number = number
            self.text = text
            self.selected = selected
        }
    }

    public var lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines
    }

    /// Nil for image, PDF and whole-file anchors, which have no lines to show.
    public static func make(from anchor: Anchor) -> ReviewExcerpt? {
        switch anchor {
        case .text(let text): return make(from: text)
        case .embeddedImage(let image): return make(from: image.embed)
        case .element(let element):
            let lines = element.text.components(separatedBy: "\n").filter { !$0.isEmpty }
            return ReviewExcerpt(lines: lines.map { Line(number: nil, text: $0, selected: true) })
        case .image, .pdf, .wholeFile: return nil
        }
    }

    static func make(from anchor: TextAnchor) -> ReviewExcerpt {
        let before = anchor.before.isEmpty ? [] : anchor.before.components(separatedBy: "\n")
        let selected = anchor.text.components(separatedBy: "\n")
        let after = anchor.after.isEmpty ? [] : anchor.after.components(separatedBy: "\n")
        var lines: [Line] = []
        for (offset, text) in before.enumerated() {
            lines.append(Line(number: anchor.start.line - before.count + offset, text: text, selected: false))
        }
        for (offset, text) in selected.enumerated() {
            lines.append(Line(number: anchor.start.line + offset, text: text, selected: true))
        }
        let afterStart = anchor.start.line + selected.count
        for (offset, text) in after.enumerated() {
            lines.append(Line(number: afterStart + offset, text: text, selected: false))
        }
        return ReviewExcerpt(lines: lines)
    }
}
