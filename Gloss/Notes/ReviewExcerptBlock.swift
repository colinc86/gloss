import Core
import SwiftUI
import Viewers

/// A titled block of a review card: the note's lines with the selection tinted and numbered, its context lines
/// dimmed around it. The same block shows the lines as sent and the lines as they are now.
struct ReviewExcerptBlock: View {
    let title: String
    let excerpt: ReviewExcerpt
    let language: String?
    let tint: Color
    /// The lines are gone from the file: shown struck, without a tint.
    var struck = false
    @Environment(\.colorScheme) private var appearance
    @State private var styled: [AttributedString] = []

    private static let shape = RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous)
    /// About ten rows; more scroll.
    private static let maxRows: CGFloat = 10
    private static let rowHeight: CGFloat = 20

    private var source: String { excerpt.lines.map { $0.text.isEmpty ? " " : $0.text }.joined(separator: "\n") }
    private var gutterWidth: CGFloat {
        let digits = excerpt.lines.compactMap(\.number).map { String($0).count }.max() ?? 0
        return digits == 0 ? 0 : CGFloat(digits) * 7 + DS.Space.xs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(struck ? Color.secondary : tint)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(excerpt.lines.enumerated()), id: \.offset) { index, line in
                        row(line, at: index)
                    }
                }
            }
            // Capped at ten rows; compressible too, so a card at its own cap shrinks the blocks rather than
            // clipping its header.
            .frame(maxHeight: Self.maxRows * Self.rowHeight)
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: Self.shape)
        .task(id: CodeSnippetKey(source, language: language, dark: appearance == .dark)) {
            styled = struck ? [] : ConflictCodeLines.highlightedLines(excerpt.lines.map(\.text), language: language, muted: false,
                                                                      appearance: appearance == .dark ? .darkAqua : .aqua)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(excerpt.lines.filter(\.selected).map(\.text).joined(separator: "\n"))
    }

    private func row(_ line: ReviewExcerpt.Line, at index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            if gutterWidth > 0 {
                Text(line.number.map(String.init) ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(line.selected ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                    .frame(width: gutterWidth, alignment: .trailing)
            }
            Text(line.selected && !struck && styled.indices.contains(index) ? styled[index] : AttributedString(line.text.isEmpty ? " " : line.text))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(line.selected && !struck ? Color.primary : Color.secondary)
                .strikethrough(struck && line.selected)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.xs)
        .frame(height: Self.rowHeight)
        .background(line.selected && !struck ? tint.opacity(0.12) : .clear)
    }
}
