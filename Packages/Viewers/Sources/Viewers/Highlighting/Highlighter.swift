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
    private let layer: LanguageLayer
    private var text: String
    /// Captures sorted by location, non-overlapping where tree-sitter guarantees it.
    public private(set) var captures: [NamedRange] = []

    public init?(languageName: String, text: String) {
        guard text.utf16.count <= Self.maximumLength, let configuration = GrammarCatalog.configuration(forLanguage: languageName) else { return nil }
        self.languageName = languageName
        self.text = text
        do {
            layer = try LanguageLayer(
                languageConfig: configuration,
                configuration: .init(maximumLanguageDepth: 3, languageProvider: { GrammarCatalog.configuration(forLanguage: $0) })
            )
        } catch {
            Self.log.error("LanguageLayer for \(languageName, privacy: .public) failed: \(error, privacy: .public)")
            return nil
        }
        layer.replaceContent(with: text)
        rehighlight()
    }

    /// Full reparse, for reloads.
    public func replaceAll(with newText: String) {
        text = newText
        layer.replaceContent(with: newText)
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
        _ = layer.didChangeContent(LanguageLayer.Content(string: newText), using: inputEdit)
        rehighlight()
    }

    private func rehighlight() {
        let full = NSRange(location: 0, length: text.utf16.count)
        do {
            captures = try layer.highlights(in: full, provider: text.predicateTextProvider).sorted { $0.range.location < $1.range.location }
        } catch {
            Self.log.error("highlight query failed: \(error, privacy: .public)")
            captures = []
        }
    }

    /// Captures overlapping `range`, by binary search on the sorted starts.
    public func captures(in range: NSRange) -> ArraySlice<NamedRange> {
        guard !captures.isEmpty else { return [] }
        let end = range.location + range.length
        var low = 0
        var high = captures.count
        while low < high {
            let mid = (low + high) / 2
            if captures[mid].range.location + captures[mid].range.length <= range.location { low = mid + 1 } else { high = mid }
        }
        var upper = low
        while upper < captures.count, captures[upper].range.location < end { upper += 1 }
        return captures[low..<upper]
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
