import AppKit
import Core
import Foundation
import Observation

/// Rendered and source views of one markdown document. Notes live in source coordinates; the rendered view maps
/// selections back through `RenderedSourceMap`.
@Observable
public final class MarkdownViewerController {
    public enum Mode: String, CaseIterable, Sendable {
        case rendered
        case source
    }

    public let source: TextEditorController
    public var mode: Mode = .rendered
    public private(set) var rendered: NSAttributedString = NSAttributedString()
    public private(set) var map = RenderedSourceMap(spans: [], blocks: [])
    public private(set) var renderedVersion = 0
    public var renderedSelection = NSRange(location: 0, length: 0)
    /// Set by the rendered view: on-screen rectangle of a rendered range.
    @ObservationIgnored public var renderedRectProvider: (NSRange) -> CGRect? = { _ in nil }
    public var pendingRenderedScroll: NSRange?
    public var pendingRenderedScrollVersion = 0
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    @ObservationIgnored private var renderedContentVersion = -1

    public init(source: TextEditorController) {
        self.source = source
        rebuildNow()
        let previous = source.onTextChange
        source.onTextChange = { [weak self] in
            previous()
            self?.scheduleRebuild()
        }
    }

    /// Re-renders immediately when the source was replaced wholesale (reload, merge).
    public func syncWithSourceIfReplaced() {
        if renderedContentVersion != source.contentVersion { rebuildNow() }
    }

    public func toggle() {
        mode = mode == .rendered ? .source : .rendered
    }

    /// Re-renders shortly after the source stops changing.
    public func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.rebuildNow()
        }
    }

    public func rebuildNow() {
        renderedContentVersion = source.contentVersion
        let output = MarkdownRenderer.render(source.text)
        rendered = output.text
        map = output.map
        renderedVersion += 1
    }

    /// The rendered selection in source coordinates, with the exact text when the mapping is exact.
    public var renderedSelectionMapping: RenderedSourceMap.Mapping? {
        map.sourceRange(forRendered: renderedSelection)
    }

    /// Source-coordinate highlights projected onto the rendered text.
    public func renderedHighlights() -> [TextHighlight] {
        source.highlights.flatMap { highlight -> [TextHighlight] in
            map.renderedRanges(forSource: highlight.range).map { range in
                var copy = highlight
                copy.range = range
                return copy
            }
        }
    }

    /// Scrolls whichever view is showing to a source range.
    public func scroll(toSource range: NSRange) {
        switch mode {
        case .source:
            source.scroll(to: range)
        case .rendered:
            if let first = map.renderedRanges(forSource: range).first {
                pendingRenderedScroll = first
                pendingRenderedScrollVersion += 1
            }
        }
    }

    public func rect(forSource range: NSRange) -> CGRect? {
        switch mode {
        case .source: source.rect(for: range)
        case .rendered: map.renderedRanges(forSource: range).first.flatMap { renderedRectProvider($0) }
        }
    }
}
