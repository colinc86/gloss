import Core
import Foundation
import OSLog
import SwiftTreeSitter
import SwiftTreeSitterLayer

/// Syntax highlighting for one text document, with injections (markdown inline, fenced code).
/// Confined to the main actor: `LanguageLayer` owns a non-Sendable parser.
public final class Highlighter {
    nonisolated private static let log = Logger(subsystem: "com.cnc.Gloss", category: "viewer")
    /// Above this many UTF-16 units highlighting is skipped; the plan's background parser can lift it later.
    public static let maximumLength = 1_000_000

    public let languageName: String
    private var layer: LanguageLayer
    /// Whether the grammar can embed other languages (markdown code blocks, HTML scripts).
    private let hasInjections: Bool
    private var text: String
    /// Captures sorted by location, non-overlapping where tree-sitter guarantees it.
    public private(set) var captures: [HighlightCapture] = [] {
        didSet {
            generation += 1
            var running = 0
            maximumEnds = captures.map { capture in
                running = max(running, capture.range.location + capture.range.length)
                return running
            }
        }
    }
    /// `maximumEnds[i]` is the furthest end among `captures[0...i]`. Captures are sorted by start, but their ends
    /// are not (an outer capture ends after the inner ones that follow it); this running maximum is, so lookups
    /// can binary-search it without skipping a long capture that began earlier.
    private var maximumEnds: [Int] = []
    /// Bumped whenever `captures` changes, so views can tell which colouring is current.
    public private(set) var generation = 0

    public init?(languageName: String, text: String) {
        guard text.utf16.count <= Self.maximumLength, let configuration = GrammarCatalog.configuration(forLanguage: languageName) else { return nil }
        self.languageName = languageName
        self.text = text
        hasInjections = configuration.queries[.injections] != nil
        do {
            layer = try Self.makeLayer(configuration, depth: Self.depth(for: text))
        } catch {
            Self.log.error("LanguageLayer for \(languageName, privacy: .public) failed: \(error, privacy: .public)")
            return nil
        }
        layer.replaceContent(with: text)
        rehighlight()
    }

    nonisolated private static func makeLayer(_ configuration: LanguageConfiguration, depth: Int = 3) throws -> LanguageLayer {
        try LanguageLayer(
            languageConfig: configuration,
            configuration: .init(maximumLanguageDepth: depth, languageProvider: { GrammarCatalog.configuration(forLanguage: $0) })
        )
    }

    /// Embedded languages (markdown inline text and code blocks, Rust macro bodies) are highlighted only in
    /// documents up to this size. Tree-sitter applies every edit to each embedded region, and markdown has one per
    /// paragraph: a keystroke cost 42 ms at 32 KB and 270 ms at 128 KB in a release build (three to four times that
    /// in debug), against 6 and 24 ms without them.
    nonisolated public static let embeddedLanguageLimit = 24_000

    nonisolated private static func depth(for text: String) -> Int {
        text.utf16.count <= embeddedLanguageLimit ? 3 : 0
    }

    private var hasSublayers: Bool { hasInjections && layer.snapshot()?.sublayerSnapshots.isEmpty == false }

    /// Full reparse, for reloads.
    public func replaceAll(with newText: String) {
        text = newText
        editCount += 1
        if hasInjections, let configuration = GrammarCatalog.configuration(forLanguage: languageName), let fresh = try? Self.makeLayer(configuration, depth: Self.depth(for: newText)) {
            layer = fresh   // a reused layer would keep stale embedded languages
        }
        layer.replaceContent(with: newText)
        mayBeStale = false
        rehighlight()
    }

    /// Incremental update. `edit` is in pre-edit UTF-16 units; `oldIndex` describes the text before the edit.
    public func apply(edit: NSRange, replacementLength: Int, newText: String, oldIndex: LineIndex, newIndex: LineIndex) {
        let startPoint = Self.point(forOffset: edit.location, index: oldIndex)
        let oldEndPoint = Self.point(forOffset: edit.location + edit.length, index: oldIndex)
        let newEndPoint = Self.point(forOffset: edit.location + replacementLength, index: newIndex)
        let inputEdit = InputEdit(
            startByte: edit.location * 2,
            oldEndByte: (edit.location + edit.length) * 2,
            newEndByte: (edit.location + replacementLength) * 2,
            startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: newEndPoint
        )
        text = newText
        // Past the size limit (a paste grew the document) highlighting stops instead of slowing every keystroke.
        if newText.utf16.count > Self.maximumLength {
            captures = []
            isDisabled = true
            return
        }
        editCount += 1
        let hadSublayers = hasSublayers
        let invalidated = layer.didChangeContent(LanguageLayer.Content(string: newText), using: inputEdit)
        rehighlight(after: edit, replacementLength: replacementLength, invalidated: invalidated, newIndex: newIndex)
        // Tree-sitter's layer does not keep embedded languages (markdown inline text and code blocks, Rust macro
        // bodies) right across edits: it keeps sublayers whose host was removed and misses new ones. Keystrokes
        // stay incremental and fast; `backgroundRebuild()` corrects the document once typing pauses. Rebuilding on
        // every keystroke cost 500 ms on 115 KB of markdown.
        if hadSublayers || hasSublayers { mayBeStale = newText.utf16.count <= Self.backgroundRebuildLimit }
    }

    /// Set once the document grows past `maximumLength`; callers stop asking for colours.
    public private(set) var isDisabled = false
    /// Embedded-language captures may be out of date until a background rebuild is adopted.
    public private(set) var mayBeStale = false
    /// Above this a full rebuild (whose cost grows faster than the text) is not attempted; colours may stay stale.
    public static let backgroundRebuildLimit = 256_000
    private var editCount = 0

    /// A fresh layer and its captures, built away from the main actor. Unchecked: the builder hands the layer over
    /// and never touches it again.
    nonisolated public final class Rebuild: @unchecked Sendable {
        fileprivate let layer: LanguageLayer
        fileprivate let captures: [HighlightCapture]
        fileprivate let version: Int

        fileprivate init(layer: LanguageLayer, captures: [HighlightCapture], version: Int) {
            self.layer = layer
            self.captures = captures
            self.version = version
        }
    }

    /// Work that builds a fresh layer for the current text, safe to run off the main actor; nil when nothing is
    /// stale. Pass its result to `adopt`.
    public func backgroundRebuild() -> (@Sendable () -> Rebuild?)? {
        guard mayBeStale else { return nil }
        let text = text
        let languageName = languageName
        let version = editCount
        let depth = layer.supportsNestedLanguages ? 3 : 0
        return { Highlighter.build(languageName: languageName, text: text, depth: depth, version: version) }
    }

    nonisolated private static func build(languageName: String, text: String, depth: Int, version: Int) -> Rebuild? {
        // The same depth the document was opened with: a rebuild never switches embedded languages on or off.
        guard let configuration = GrammarCatalog.configuration(forLanguage: languageName), let layer = try? makeLayer(configuration, depth: depth) else { return nil }
        layer.replaceContent(with: text)
        guard let named = try? layer.highlights(in: NSRange(location: 0, length: text.utf16.count), provider: text.predicateTextProvider) else { return nil }
        return Rebuild(layer: layer, captures: named.compactMap(HighlightCapture.init).sorted(by: order), version: version)
    }

    /// Takes a background rebuild when the text has not changed since it started; returns whether it did.
    @discardableResult
    public func adopt(_ rebuild: Rebuild) -> Bool {
        guard rebuild.version == editCount else { return false }
        layer = rebuild.layer
        captures = rebuild.captures
        mayBeStale = false
        return true
    }

    /// Re-queries only what the edit invalidated (tree-sitter's changed ranges plus the edited text, widened to
    /// whole lines) and shifts every other capture. Querying the whole document on each keystroke cost 68 ms on
    /// an 81 KB file in a release build (340 ms in debug), close to a second near the size limit.
    private func rehighlight(after edit: NSRange, replacementLength: Int, invalidated: IndexSet, newIndex: LineIndex) {
        let length = text.utf16.count
        // What to query again, in post-edit coordinates, widened to whole lines.
        var region = invalidated
        region.insert(integersIn: edit.location..<min(length, edit.location + max(replacementLength, 1)))
        // Captures touching the edit at either end can change too (a string grows when a quote is typed after
        // it), so their whole extent is re-queried.
        let delta = replacementLength - edit.length
        let oldEnd = edit.location + edit.length
        func mark(_ lower: Int, _ upper: Int) {
            let low = max(0, min(lower, length))
            let high = max(low, min(upper, length))
            if high > low { region.insert(integersIn: low..<high) } else if low < length { region.insert(low) }
        }
        for capture in captures {
            let end = capture.range.location + capture.range.length
            if end == edit.location || (end > edit.location && capture.range.location < oldEnd) {
                // Old coordinates up to the edit are unchanged; whatever lay inside the replaced text is gone.
                let start = min(capture.range.location, edit.location)
                mark(start, max(start + 1, edit.location + replacementLength))
            } else if capture.range.location == oldEnd {
                mark(capture.range.location + delta, max(capture.range.location + delta + 1, end + delta))
            }
        }
        // One span from the line before the first invalidated line to the line after the last, as a single query:
        // a capture crossing two separate pieces would otherwise come back twice, and the query's own duplicates
        // must stay as a fresh parse has them.
        guard let low = region.first, let high = region.last else {
            rehighlight()   // nothing left to re-query (the document became empty): start over
            return
        }
        let firstLine = newIndex.range(ofLine: max(1, newIndex.position(forUTF16Offset: low).line - 1))
        let lastLine = newIndex.range(ofLine: min(newIndex.lineCount, newIndex.position(forUTF16Offset: min(high + 1, length)).line + 1))
        let span = NSRange(location: firstLine.location, length: max(0, min(length, lastLine.location + lastLine.length) - firstLine.location))
        // The re-queried region, with one rule for both lists so they cannot overlap: a capture belongs to it when
        // it overlaps the span, or (zero-length) sits on or between its ends. The query reaches one unit further so
        // zero-length captures at either end are returned; matches also return captures outside the span, which stay
        // with the kept list.
        func inRegion(_ capture: HighlightCapture) -> Bool {
            capture.range.length == 0
                ? capture.range.location >= span.location && capture.range.location <= span.location + span.length
                : NSIntersectionRange(capture.range, span).length > 0
        }
        do {
            let queryStart = max(0, span.location - 1)
            let queried = NSRange(location: queryStart, length: min(length, span.location + span.length + 1) - queryStart)
            let fresh = try layer.highlights(in: queried, provider: text.predicateTextProvider).compactMap(HighlightCapture.init).filter(inRegion)
            // One pass over the old captures: drop those the edit touched, shift those after it, and drop any
            // that fall in a re-queried line (the query returned them again). Order is preserved.
            var kept: [HighlightCapture] = []
            kept.reserveCapacity(captures.count)
            for var capture in captures {
                let end = capture.range.location + capture.range.length
                if end <= edit.location {
                } else if capture.range.location >= oldEnd {
                    capture.range.location += delta
                } else {
                    continue
                }
                if inRegion(capture) { continue }
                kept.append(capture)
            }
            captures = Self.merge(kept, fresh.sorted(by: Self.order))
        } catch {
            Self.log.error("highlight query failed: \(error, privacy: .public)")
            rehighlight()
        }
    }

    /// Merges two lists already in `order`.
    nonisolated static func merge(_ a: [HighlightCapture], _ b: [HighlightCapture]) -> [HighlightCapture] {
        var result: [HighlightCapture] = []
        result.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if order(b[j], a[i]) { result.append(b[j]); j += 1 } else { result.append(a[i]); i += 1 }
        }
        result.append(contentsOf: a[i...])
        result.append(contentsOf: b[j...])
        return result
    }

    /// Start, then longer first, then name: the same order whichever way captures were computed.
    nonisolated static func order(_ a: HighlightCapture, _ b: HighlightCapture) -> Bool {
        if a.range.location != b.range.location { return a.range.location < b.range.location }
        if a.range.length != b.range.length { return a.range.length > b.range.length }
        return a.name < b.name
    }

    private func rehighlight() {
        let full = NSRange(location: 0, length: text.utf16.count)
        do {
            captures = try layer.highlights(in: full, provider: text.predicateTextProvider).compactMap(HighlightCapture.init).sorted(by: Self.order)
        } catch {
            Self.log.error("highlight query failed: \(error, privacy: .public)")
            captures = []
        }
    }

    /// Captures overlapping `range`: the first capture that could reach into it is found by binary search on
    /// the running maximum of ends, then captures are scanned until they start past its end.
    public func captures(in range: NSRange) -> [HighlightCapture] {
        guard !captures.isEmpty else { return [] }
        let end = range.location + range.length
        var low = 0
        var high = captures.count
        while low < high {
            let mid = (low + high) / 2
            if maximumEnds[mid] <= range.location { low = mid + 1 } else { high = mid }
        }
        var result: [HighlightCapture] = []
        var index = low
        while index < captures.count, captures[index].range.location < end {
            let capture = captures[index]
            if capture.range.location + capture.range.length > range.location { result.append(capture) }
            index += 1
        }
        return result
    }

    /// The smallest syntax node strictly containing `range`, for expand-selection.
    public func enclosingNodeRange(of range: NSRange) -> NSRange? {
        guard let snapshot = layer.snapshot(), let root = snapshot.rootSnapshot.tree.rootNode else { return nil }
        let bytes = UInt32(range.location * 2)..<UInt32((range.location + range.length) * 2)
        var node = root.descendant(in: bytes)
        while let current = node {
            let candidate = current.range
            if candidate.location < range.location || candidate.location + candidate.length > range.location + range.length {
                if candidate.length > range.length { return candidate }
            }
            node = current.parent
        }
        return nil
    }

    nonisolated static func point(forOffset offset: Int, index: LineIndex) -> Point {
        let position = index.position(forUTF16Offset: offset)
        return Point(row: position.line - 1, column: (position.col - 1) * 2)
    }
}

/// One highlighted span: the capture name from the highlight query and its UTF-16 range. Unlike tree-sitter's
/// `NamedRange` it carries no row/column points, so captures after an edit can simply be shifted.
nonisolated public struct HighlightCapture: Sendable, Hashable {
    public var name: String
    public var range: NSRange

    public init(name: String, range: NSRange) {
        self.name = name
        self.range = range
    }

    /// Nil for zero-length captures: they colour nothing, and error recovery creates them away from any range
    /// tree-sitter reports as changed, so keeping them would make incremental results drift from a fresh parse.
    init?(_ named: NamedRange) {
        guard named.range.length > 0 else { return nil }
        self.init(name: named.name, range: named.range)
    }
}
