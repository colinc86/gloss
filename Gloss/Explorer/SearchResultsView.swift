import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers
import Viewers

/// Content-search results: a summary, then one collapsible group per file (icon, name, folder, count) with each
/// matching line and the match itself lit up, so the eye sees why the line matched before opening it.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<String> = []

    var body: some View {
        let search = model.explorer.contentSearch
        let groups = search.groupedHits
        let root = model.explorer.selectedTab?.path ?? "/"
        VStack(spacing: 0) {
            if let error = search.errorMessage {
                Notice(kind: .warning, symbol: "exclamationmark.magnifyingglass", title: "Search failed", detail: error) { EmptyView() }
                    .padding(DS.Space.s)
                Spacer()
            } else if !search.isSearching, search.searchedPattern == nil {
                EmptyState(symbol: "text.magnifyingglass", title: "Search this folder",
                           message: "Type text and press Return. Turn on .* for a regular expression.")
            } else if !search.isSearching, search.hits.isEmpty, search.searchedPattern != nil {
                EmptyState(symbol: "text.magnifyingglass", title: "No matches",
                           message: search.searchedPattern?.regex == true ? "Nothing matches that pattern here." : "Nothing in this folder contains that text.")
            } else {
                summary(search, files: groups.count)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.path) { group in
                            Section {
                                if !collapsed.contains(group.path) {
                                    ForEach(group.hits) { hit in
                                        // Prose stays plain: a lone markdown line out of context colours as noise (a list number in red).
                                        SearchHitRow(hit: hit, pattern: search.searchedPattern,
                                                     language: GrammarCatalog.languageName(forPath: group.path).flatMap { $0.hasPrefix("markdown") ? nil : $0 }) {
                                            model.openDocument(hostID: model.explorer.selectedTab?.hostID ?? .local, path: hit.path, line: hit.line)
                                        }
                                    }
                                }
                            } header: {
                                groupHeader(group.path, count: group.hits.count, root: root)
                            }
                        }
                        if search.truncated {
                            Text("Showing the first 500 matches")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(DS.Space.m)
                        }
                    }
                }
            }
        }
    }

    private func summary(_ search: ContentSearchModel, files: Int) -> some View {
        HStack(spacing: DS.Space.s) {
            if search.isSearching {
                ProgressView().controlSize(.mini)
                Text("Searching…")
            } else {
                let count = search.hits.count
                // ripgrep reports lines, so the count is of matching lines, not of occurrences.
                Text("\(count)\(search.truncated ? "+" : "") \(count == 1 ? "line" : "lines") in \(files) \(files == 1 ? "file" : "files")")
                    .contentTransition(.numericText(value: Double(count)))
            }
            Spacer()
            if !collapsed.isEmpty || files > 1 {
                Button(collapsed.isEmpty ? "Collapse All" : "Expand All") {
                    withAnimation(DS.Motion.smooth) {
                        collapsed = collapsed.isEmpty ? Set(search.groupedHits.map(\.path)) : []
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
    }

    private func groupHeader(_ path: String, count: Int, root: String) -> some View {
        let relative = PathUtilities.relative(path, to: root)
        let name = (relative as NSString).lastPathComponent
        let folder = (relative as NSString).deletingLastPathComponent
        let isOpen = !collapsed.contains(path)
        return Button {
            withAnimation(DS.Motion.smooth) {
                if isOpen { collapsed.insert(path) } else { collapsed.remove(path) }
            }
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data))
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: DS.Space.xs)
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Space.xs + 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(.bar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
    }
}

/// One matching line: its number in a gutter, the line with every match highlighted, and a hover state.
struct SearchHitRow: View {
    let hit: SearchHit
    let pattern: (text: String, regex: Bool)?
    /// The file's language, so the line keeps the editor's colours under the match wash.
    var language: String? = nil
    let open: () -> Void
    @State private var hovering = false
    /// Worked out once per row (a highlighter parses the line), not on every redraw.
    @State private var coloured: AttributedString?

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text("\(hit.line)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
                Text(coloured ?? SearchHitRow.highlighted(hit.text, pattern: pattern))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, DS.Space.xs)
            .padding(.trailing, DS.Space.m)
            .padding(.leading, DS.Space.s)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
            .padding(.horizontal, DS.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help("Open at line \(hit.line)")
        .task(id: hit.text) {
            guard language != nil else { return }
            coloured = SearchHitRow.highlighted(hit.text, pattern: pattern, language: language)
        }
    }

    /// The line without its indentation, with each match of the searched text (or pattern) on an accent wash.
    static func highlighted(_ line: String, pattern: (text: String, regex: Bool)?, language: String? = nil) -> AttributedString {
        let trimmed = String(line.drop { $0 == " " || $0 == "\t" })
        var result = AttributedString(trimmed)
        // Syntax colours first, as SwiftUI colours so the match can override them; the match wash goes on top.
        if var syntax = SyntaxTheme.highlighted(trimmed, language: language), String(syntax.characters) == trimmed {
            for run in syntax.runs {
                guard let color = run.appKit.foregroundColor else { continue }
                syntax[run.range].foregroundColor = Color(nsColor: color)
            }
            result = syntax
        }
        guard let pattern, !pattern.text.isEmpty else { return result }
        let ns = trimmed as NSString
        var ranges: [NSRange] = []
        if pattern.regex {
            if let expression = try? NSRegularExpression(pattern: pattern.text) {
                ranges = expression.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)).map(\.range).filter { $0.length > 0 }
            }
        } else {
            // ripgrep's smart case: an all-lowercase query matches any case.
            let options: NSString.CompareOptions = pattern.text == pattern.text.lowercased() ? [.caseInsensitive] : []
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let found = ns.range(of: pattern.text, options: options, range: search)
                guard found.location != NSNotFound, found.length > 0 else { break }
                ranges.append(found)
                search = NSRange(location: found.location + found.length, length: ns.length - found.location - found.length)
            }
        }
        for range in ranges {
            guard let swiftRange = Range(range, in: trimmed),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result) else { continue }
            result[lower..<upper].backgroundColor = Color.accentColor.opacity(0.28)
            result[lower..<upper].foregroundColor = .primary
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}
