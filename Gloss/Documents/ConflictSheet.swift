import AppKit
import Core
import SwiftUI
import Viewers

/// Shown when the file on disk changed since it was opened: your edits next to the disk's, against the version you
/// started from, with what each choice will do.
struct ConflictSheet: View {
    let session: DocumentSession
    let conflict: DocumentSession.ConflictState

    var body: some View {
        ConflictContent(
            fileName: session.fileName, language: GrammarCatalog.languageName(forPath: session.path), regions: conflict.regions, originals: conflict.originals, canMerge: conflict.canMerge, canSaveAs: session.hostID == .local,
            saveAs: { Task { await session.saveAs() } },
            takeDisk: { Task { await session.takeTheirs() } },
            keepMine: { Task { await session.keepMine() } },
            merge: { Task { await session.mergeAndSave() } }
        )
    }
}

/// The sheet's content without a session, so every case can be rendered and reviewed on its own.
struct ConflictContent: View {
    let fileName: String
    var language: String? = nil
    let regions: [MergeRegion]
    /// The lines each region stands in for, as opened (empty when not known).
    var originals: [[String]] = []
    let canMerge: Bool
    let canSaveAs: Bool
    let saveAs: () -> Void
    let takeDisk: () -> Void
    let keepMine: () -> Void
    let merge: () -> Void
    /// Off only for offscreen renders, which do not draw scroll view content.
    var scrolls = true

    static let mineTint = Color.blue
    static let diskTint = Color.green
    static let conflictTint = Color.orange

    /// Counts of each kind of change, for the summary line.
    static func summary(_ regions: [MergeRegion]) -> String {
        var mine = 0, disk = 0, both = 0, conflicts = 0
        for region in regions {
            switch region {
            case .mine: mine += 1
            case .theirs: disk += 1
            case .both: both += 1
            case .conflict: conflicts += 1
            case .unchanged: break
            }
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
        let parts = [count(mine, "change of yours", "changes of yours"), count(disk, "change from disk", "changes from disk"),
                     count(both, "made on both sides", "made on both sides"), count(conflicts, "conflict", "conflicts")].compactMap { $0 }
        return parts.isEmpty ? "No differences" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: canMerge ? "arrow.triangle.merge" : "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(canMerge ? Color.accentColor : Self.conflictTint)
                    .frame(width: 40, height: 40)
                    .background((canMerge ? Color.accentColor : Self.conflictTint).opacity(0.14), in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("\(fileName) changed on disk").font(.title3.weight(.semibold))
                    Text(canMerge
                         ? "Your edits and the changes on disk don't overlap, so both can be kept."
                         : "Some of your edits overlap changes made on disk. Choose which version to keep.")
                        .foregroundStyle(.secondary)
                    Text(Self.summary(regions))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, DS.Space.xxs)
                }
            }
            Group {
                if scrolls {
                    ScrollView { regionList }
                } else {
                    regionList.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(minHeight: 240)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            HStack(spacing: DS.Space.s) {
                if canSaveAs {
                    Button("Save Mine As…", action: saveAs)
                        .help("Write your version to a new file and leave the one on disk alone")
                }
                Spacer()
                Button("Use Disk Version", action: takeDisk)
                    .help("Discard your unsaved edits and load the file as it is on disk")
                // Overwriting someone else's change is never the default: with a real conflict Return does
                // nothing and a choice has to be made.
                Button("Keep Mine", action: keepMine)
                    .help("Overwrite the file on disk with your version")
                if canMerge {
                    Button("Merge and Save", action: merge)
                        .help("Keep both your edits and the changes on disk, then save")
                        .modifier(PrimaryIf(true))
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(minWidth: 680, idealWidth: 820, minHeight: 460)
    }

    private var regionList: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(Array(regions.enumerated()), id: \.offset) { index, region in
                MergeRegionView(region: region, original: index < originals.count ? originals[index] : [],language: language)
            }
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The default action gets the prominent style and Return.
private struct PrimaryIf: ViewModifier {
    let isPrimary: Bool
    init(_ isPrimary: Bool) { self.isPrimary = isPrimary }

    func body(content: Content) -> some View {
        if isPrimary {
            content.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

/// One stretch of the merge: unchanged context (folded when long), a change from one side with a coloured bar and
/// label, or a conflict as two cards side by side.
private struct MergeRegionView: View {
    let region: MergeRegion
    /// The lines the region stands in for, as opened.
    let original: [String]
    var language: String? = nil

    var body: some View {
        switch region {
        case .unchanged(let lines):
            lineBlock(fold(lines), tint: nil)
        case .mine(let lines):
            change(lines, "Yours", removed: "Removed by you", tint: ConflictContent.mineTint)
        case .theirs(let lines):
            change(lines, "On disk", removed: "Removed on disk", tint: ConflictContent.diskTint)
        case .both(let lines):
            change(lines, "Both", removed: "Removed on both sides", tint: .teal)
        case .conflict(let mine, let theirs):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Label("Conflict", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ConflictContent.conflictTint)
                HStack(alignment: .top, spacing: DS.Space.s) {
                    side("Yours", mine, tint: ConflictContent.mineTint)
                    side("On disk", theirs, tint: ConflictContent.diskTint)
                }
            }
            .padding(DS.Space.s)
            .background(ConflictContent.conflictTint.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(ConflictContent.conflictTint.opacity(0.35)))
        }
    }

    /// A change, or for one that only deletes (no lines of its own), the lines it deleted struck through: an empty
    /// block said nothing about what Keep Mine or Merge would remove.
    @ViewBuilder
    private func change(_ lines: [String], _ title: String, removed: String, tint: Color) -> some View {
        if lines.isEmpty, !original.isEmpty {
            labelled(removed, tint: tint) { lineBlock(original, tint: tint, struck: true) }
        } else {
            labelled(title, tint: tint) { lineBlock(lines, tint: tint) }
        }
    }

    private func fold(_ lines: [String], keep: Int = 2) -> [String] {
        guard lines.count > keep * 2 + 1 else { return lines }
        return Array(lines.prefix(keep)) + ["⋯ \(lines.count - keep * 2) unchanged lines"] + Array(lines.suffix(keep))
    }

    private func labelled(_ title: String, tint: Color, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Capsule().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(tint).padding(.leading, DS.Space.s)
                content()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func side(_ title: String, _ lines: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if lines.isEmpty, !original.isEmpty {
                Text("\(title): removed").font(.caption2.weight(.semibold)).foregroundStyle(tint)
                lineBlock(original, tint: tint, struck: true)
            } else {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(tint)
                lineBlock(lines.isEmpty ? ["(removed)"] : lines, tint: tint)
            }
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous))
    }

    private func lineBlock(_ lines: [String], tint: Color?, struck: Bool = false) -> some View {
        ConflictCodeLines(lines: lines,language: language,tint: tint,struck: struck)
    }
}

/// Parse one bounded block, rather than creating a highlighter/task for every displayed line.
/// Context/removal text remains muted; Gloss keeps the original uncolored conflict-sheet appearance.
struct ConflictCodeLines: View {
    let lines: [String]
    let language: String?
    let tint: Color?
    let struck: Bool
    @Environment(\.colorScheme) private var appearance
    @State private var styled: [AttributedString] = []
    private struct TaskKey: Hashable { let snippet: CodeSnippetKey; let muted: Bool }
    private var muted: Bool { tint == nil || struck }
    private var source: String { lines.map { $0.isEmpty ? " " : $0 }.joined(separator: "\n") }
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            ForEach(Array(lines.enumerated()),id: \.offset) { index, line in
                Text(!muted && styled.indices.contains(index) ? styled[index] : AttributedString(line.isEmpty ? " " : line))
                    .font(.system(.callout,design: .monospaced))
                    .foregroundStyle(tint == nil || struck ? (line.hasPrefix("⋯") ? Color.secondary.opacity(0.7) : Color.secondary) : Color.primary)
                    .strikethrough(struck)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity,alignment: .leading)
                    .padding(.horizontal,DS.Space.s)
                    .padding(.vertical,1)
                    .background(tint.map { $0.opacity(0.1) } ?? .clear)
            }
        }
        .task(id: TaskKey(snippet: CodeSnippetKey(source,language: language,dark: appearance == .dark),muted: muted)) {
            styled = Self.highlightedLines(lines,language: language,muted: tint == nil || struck,appearance: appearance == .dark ? .darkAqua : .aqua)
        }
    }
    static func highlightedLines(_ lines: [String],language: String?,muted: Bool,appearance: NSAppearance.Name) -> [AttributedString] {
        let theme = ActiveCodeTheme.theme(for: NSAppearance(named: appearance) ?? NSApp.effectiveAppearance)
        guard !muted, theme.id != "gloss" else { return [] }
        let text = lines.map { $0.isEmpty ? " " : $0 }.joined(separator: "\n")
        guard let highlighted = SyntaxTheme.highlighted(text,language: language,appearance: appearance) else { return [] }
        var offset = 0
        return lines.map { line in
            let length = (line.isEmpty ? " " : line).utf16.count
            defer { offset += length + 1 }
            guard let range = Range(NSRange(location: offset,length: length),in: text),
                  let lower = AttributedString.Index(range.lowerBound,within: highlighted),
                  let upper = AttributedString.Index(range.upperBound,within: highlighted) else { return AttributedString(line) }
            return AttributedString(highlighted[lower..<upper])
        }
    }
}
