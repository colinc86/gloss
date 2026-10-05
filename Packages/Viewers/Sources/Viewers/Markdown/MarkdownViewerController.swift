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
    /// "412 words · 2 min read", counted on the rendered text (no markup), refreshed with each render.
    public var readingSummary: String {
        if summaryVersion != renderedVersion {
            summaryVersion = renderedVersion
            cachedSummary = Self.readingSummary(for: rendered.string)
        }
        return cachedSummary
    }
    @ObservationIgnored private var summaryVersion = -1
    @ObservationIgnored private var cachedSummary = ""

    nonisolated static func readingSummary(for text: String) -> String {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let minutes = max(1, Int((Double(words) / 230).rounded()))
        return "\(words.formatted()) word\(words == 1 ? "" : "s") · \(minutes) min read"
    }
    public var renderedSelection = NSRange(location: 0, length: 0)
    /// Set by the rendered view: on-screen rectangle of a rendered range.
    @ObservationIgnored public var renderedRectProvider: (NSRange) -> CGRect? = { _ in nil }
    /// Where the rendered view's notes are on screen; in source mode the source editor's `noteGeometry` applies.
    @ObservationIgnored public let noteGeometry = NoteGeometry()
    public var pendingRenderedScroll: NSRange?
    public var pendingRenderedScrollVersion = 0
    /// See `TextEditorController.pendingScrollSelects`.
    public private(set) var pendingRenderedScrollSelects = true
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    @ObservationIgnored private var renderedContentVersion = -1

    /// The document's folder on this Mac, for relative images; nil for remote documents.
    public let baseURL: URL?
    /// The document's folder on its own host, for relative links; nil where links to files mean nothing (a pull
    /// request's or a ticket's Markdown).
    @ObservationIgnored public var documentDirectory: String?
    /// Opens a relative or file: link's target as a document on the same host.
    @ObservationIgnored public var onOpenDocument: (String) -> Void = { _ in }

    public init(source: TextEditorController, baseURL: URL? = nil) {
        self.source = source
        self.baseURL = baseURL
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
        let output = MarkdownRenderer.render(source.text, baseURL: baseURL)
        rendered = output.text
        map = output.map
        renderedVersion += 1
    }

    /// Collapses the rendered view's selection to its end. The view ignores its own delegate while applying a
    /// scroll, so the controller's copy is updated here as well.
    public func collapseRenderedSelection() {
        guard renderedSelection.length > 0 else { return }
        let end = NSRange(location: renderedSelection.location + renderedSelection.length, length: 0)
        renderedSelection = end
        pendingRenderedScroll = end
        pendingRenderedScrollSelects = true
        pendingRenderedScrollVersion += 1
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
    public func scroll(toSource range: NSRange, select: Bool = true) {
        switch mode {
        case .source:
            source.scroll(to: range, select: select)
        case .rendered:
            if let first = map.renderedRanges(forSource: range).first {
                pendingRenderedScroll = first
                pendingRenderedScrollSelects = select
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
