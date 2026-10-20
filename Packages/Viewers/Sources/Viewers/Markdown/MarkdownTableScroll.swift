import AppKit

/// A table wider than the text column scrolls sideways within it, as a web page's does. Its rows stay text in the
/// page, so selecting, finding and noting what is in a cell work as anywhere else: scrolling lays its rows out again
/// moved left (their indents, tab stops and chrome), into room the renderer leaves left of the column
/// (`MarkdownRenderer.Output.inset`), and `MarkdownLayoutFragment` clips them to the column.
enum MarkdownTableScroll {
    struct Table: Equatable {
        let id: Int
        /// Each row's paragraph, its newline included.
        var rows: [NSRange]
        let overflow: CGFloat
        /// The part of the container the table shows in, in container coordinates.
        let visible: ClosedRange<CGFloat>
        /// All of its text.
        var range: NSRange {
            guard let first = rows.first, let last = rows.last else { return NSRange(location: 0, length: 0) }
            return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        }
    }

    /// The tables in `text` wider than the column, by id.
    static func wideTables(in text: NSAttributedString) -> [Int: Table] {
        var tables: [Int: Table] = [:]
        text.enumerateAttribute(MarkdownRenderer.blockKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let chrome = (value as? MarkdownBlockDecoration)?.table, chrome.overflow > 0 else { return }
            tables[chrome.id, default: Table(id: chrome.id, rows: [], overflow: chrome.overflow, visible: chrome.visible)].rows.append(range)
        }
        return tables
    }

    /// Lays `table`'s rows out `offset` points left of where they start, from their unscrolled attributes in `base`
    /// (the same text as `storage`).
    static func scroll(_ table: Table, to offset: CGFloat, in storage: NSTextStorage, base: NSAttributedString) {
        storage.beginEditing()
        defer { storage.endEditing() }
        for row in table.rows where NSMaxRange(row) <= storage.length && NSMaxRange(row) <= base.length && row.length > 0 {
            if let style = base.attribute(.paragraphStyle, at: row.location, effectiveRange: nil) as? NSParagraphStyle {
                storage.addAttribute(.paragraphStyle, value: shifted(style, by: offset), range: row)
            }
            if let decoration = base.attribute(MarkdownRenderer.blockKey, at: row.location, effectiveRange: nil) as? MarkdownBlockDecoration {
                storage.addAttribute(MarkdownRenderer.blockKey, value: decoration.scrolled(by: offset), range: row)
            }
        }
    }

    static func shifted(_ style: NSParagraphStyle, by offset: CGFloat) -> NSParagraphStyle {
        guard offset != 0, let moved = style.mutableCopy() as? NSMutableParagraphStyle else { return style }
        moved.headIndent -= offset
        moved.firstLineHeadIndent -= offset
        moved.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location - offset, options: $0.options) }
        return moved
    }
}

extension MarkdownBlockDecoration {
    /// A table row's chrome moved `offset` points left, as scrolled; its quote bars and where it shows stay put.
    func scrolled(by offset: CGFloat) -> MarkdownBlockDecoration {
        guard var chrome = table else { return self }
        chrome.dividers = chrome.dividers.map { $0 - offset }
        chrome.offset = offset
        return MarkdownBlockDecoration(kind: kind, leading: leading - offset, quoteBars: quoteBars, label: label, codeBackground: codeBackground,
                                       codeForeground: codeForeground, table: chrome)
    }
}

/// The rendered view's layout manager. A wide table's cells lie partly outside the column, clipped where they are
/// drawn; selection and highlight segments are cut to the column too, so the view's selection, note highlights and
/// the rects notes are pointed at keep to what shows. Other segments (a caret, a cell's whole frame) are whole.
nonisolated final class MarkdownTextLayoutManager: NSTextLayoutManager {
    /// The text column in container coordinates when the container is wider than it (a page with a wide table):
    /// a selection over several lines runs the container's width, so every segment is cut to it.
    var column: ClosedRange<CGFloat>?

    override func enumerateTextSegments(in textRange: NSTextRange, type: NSTextLayoutManager.SegmentType, options: NSTextLayoutManager.SegmentOptions = [],
                                        using block: (NSTextRange?, CGRect, CGFloat, NSTextContainer) -> Bool) {
        guard type == .selection || type == .highlight else {
            return super.enumerateTextSegments(in: textRange, type: type, options: options, using: block)
        }
        super.enumerateTextSegments(in: textRange, type: type, options: options) { range, frame, baseline, container in
            guard let shown = shown(frame) else { return true }
            return block(range, shown, baseline, container)
        }
    }

    /// `frame` (container coordinates) cut to what shows of a wide table's row; nil when none of it does. An empty
    /// range's segment (no width) is kept as it is: AppKit sizes the view from the one at the end of the text, and
    /// without it a page with a table stayed one screen tall and could not be scrolled.
    func shown(_ frame: CGRect) -> CGRect? {
        guard frame.width > 0 else { return frame }
        var frame = frame
        if let column {
            frame = frame.intersection(CGRect(x: column.lowerBound, y: frame.minY, width: column.upperBound - column.lowerBound, height: frame.height))
            if frame.isNull || frame.width <= 0 { return nil }
        }
        guard let fragment = textLayoutFragment(for: CGPoint(x: 0, y: frame.midY)) as? MarkdownLayoutFragment,
              let chrome = fragment.decoration.table, chrome.overflow > 0 else { return frame }
        let clipped = frame.intersection(CGRect(x: chrome.visible.lowerBound, y: frame.minY, width: chrome.visible.upperBound - chrome.visible.lowerBound,
                                                height: frame.height))
        return clipped.isNull || clipped.width <= 0 ? nil : clipped
    }
}
