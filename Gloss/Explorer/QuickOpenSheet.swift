import AppKit
import Core
import SwiftUI
import Viewers
import UniformTypeIdentifiers

/// The Open Quickly panel: type to filter, arrows to move, Return to open, Escape to close. A large field, real file
/// icons, the typed characters lit up in each name, and one selection highlight that glides between rows. An
/// address typed opens as a page from the top row; pages visited before are listed above the files.
struct QuickOpenSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @Namespace private var selection
    /// The results' laid-out height; the list is exactly this tall, up to `maximumListHeight`, as Spotlight's is.
    @State private var listHeight: CGFloat = 0
    private static let maximumListHeight: CGFloat = 330
    private static let emptyHeight: CGFloat = 240

    var body: some View {
        @Bindable var quick = model.quickOpen
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "magnifyingglass")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Open quickly", text: $quick.query, prompt: Text(quick.root == nil ? "Open a web address or a page you visited" : "Open quickly"))
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit(open)
                    .onKeyPress(.downArrow) { quick.moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { quick.moveSelection(by: -1); return .handled }
                if quick.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, DS.Space.l + 2)
            .padding(.vertical, DS.Space.l)
            Divider()
            content(quick)
            Divider()
            footer(quick)
        }
        .frame(width: 600)
        .onAppear { focused = true }
        .onExitCommand { quick.dismiss() }
    }

    @ViewBuilder
    private func content(_ quick: QuickOpenModel) -> some View {
        if let error = quick.errorMessage {
            EmptyState(symbol: "exclamationmark.triangle", title: "Can't list files", message: error)
                .frame(height: Self.emptyHeight)
        } else if !quick.isLoading, quick.rows.isEmpty {
            EmptyState(
                symbol: quick.root == nil ? "globe" : quick.query.isEmpty ? "folder" : "questionmark.folder",
                title: quick.root == nil ? (quick.query.isEmpty ? "No folder open" : "Nothing matches") : quick.query.isEmpty ? "No files" : "Nothing matches",
                message: quick.root == nil ? "Type a web address, like example.com or localhost:3000, or part of a page you visited."
                    : quick.query.isEmpty ? "This folder has no files to open." : "Try fewer letters; they only need to appear in order."
            )
            .frame(height: Self.emptyHeight)
        } else {
            let rows = quick.rows
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            // Keyed by the row: an index id would keep stale rows when the results change.
                            if let header = Self.header(before: index, in: rows) {
                                Text(header)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, DS.Space.m)
                                    .padding(.top, index == 0 ? DS.Space.xs : DS.Space.s)
                                    .padding(.bottom, 2)
                            }
                            row(item, query: quick.query, selected: index == quick.selectedIndex)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    quick.selectedIndex = index
                                    open()
                                }
                        }
                    }
                    .padding(DS.Space.s)
                    .animation(DS.Motion.snappy, value: quick.selectedIndex)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        withAnimation(DS.Motion.smooth) { listHeight = height }
                    }
                }
                // Fits the results: two matches make a short list, many make it scroll. Never collapses to nothing
                // while the first listing loads.
                .frame(height: min(Self.maximumListHeight, max(listHeight, 60)))
                .onChange(of: quick.selectedIndex) { _, index in
                    let rows = quick.rows
                    guard rows.indices.contains(index) else { return }
                    withAnimation(DS.Motion.smooth) { proxy.scrollTo(rows[index].id) }
                }
            }
        }
    }

    /// "Web pages" over the first page and "Files" over the first file, when both kinds are listed.
    static func header(before index: Int, in rows: [QuickOpenModel.Row]) -> String? {
        let hasPages = rows.contains { if case .page = $0 { true } else { false } }
        let hasFiles = rows.contains { if case .file = $0 { true } else { false } }
        guard hasPages, hasFiles || rows.first.map({ if case .address = $0 { true } else { false } }) == true else { return nil }
        let previous = index > 0 ? rows[index - 1] : nil
        switch (rows[index], previous) {
        case (.page, .page?): return nil
        case (.page, _): return "Web Pages"
        case (.file, .file?): return nil
        case (.file, _): return "Files"
        default: return nil
        }
    }

    private func row(_ item: QuickOpenModel.Row, query: String, selected: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            switch item {
            case .address(let url):
                Image(systemName: "globe")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 18, height: 18)
                Text("Open \(WebDocumentKey.normalize(url))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let via = model.via(for: url, on: model.addressHost, chosen: false) {
                    Text("via \(model.hosts.entry(for: via)?.name ?? "")")
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            case .page(let page):
                Image(systemName: page.pinned ? "pin" : "clock")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(Self.highlighted(page.title ?? Core.Document.displayName(of: page.url), query: query))
                    .lineLimit(1)
                if page.title != nil {
                    Text(Core.Document.displayName(of: page.url))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if page.hostID != .web {
                    Text("via \(model.hosts.entry(for: page.hostID)?.name ?? "")")
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            case .file(let path):
                let name = (path as NSString).lastPathComponent
                let folder = (path as NSString).deletingLastPathComponent
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(Self.highlighted(name, query: QuickOpenModel.nameQuery(query, root: model.quickOpen.root ?? "/")))
                    .lineLimit(1)
                if !folder.isEmpty {
                    Text(folder)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                if let root = model.quickOpen.root,
                   let mark = model.explorer.mark(hostID: model.quickOpen.hostID, path: PathUtilities.join(root, path)) {
                    NoteMarkBadge(mark: mark)
                }
            }
            if selected {
                KeyCap("↩")
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .font(.body)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
                    .matchedGeometryEffect(id: "selection", in: selection)
            }
        }
    }

    /// The name with the query's characters (matched in order, ignoring case and accents as the ranking does) in the
    /// accent color and bold; the rest at regular weight, so the eye sees why each file matched.
    static func highlighted(_ name: String, query: String) -> AttributedString {
        var result = AttributedString(name)
        let needle = FuzzyMatcher.folded(query.filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return result }
        var index = result.startIndex
        var next = 0
        for character in name {
            let end = result.index(afterCharacter: index)
            if next < needle.count, FuzzyMatcher.fold(character) == needle[next] {
                result[index..<end].foregroundColor = .accentColor
                result[index..<end].inlinePresentationIntent = .stronglyEmphasized
                next += 1
            }
            index = end
        }
        // Only light letters when the whole query matched in the name; a match through the folder path stays plain.
        return next == needle.count ? result : AttributedString(name)
    }

    /// "12 files · 3 pages"; only pages without a folder, only files when no page matches.
    static func countLine(files: Int?, pages: Int) -> String {
        let pageText = "\(pages) \(pages == 1 ? "page" : "pages")"
        guard let files else { return pageText }
        let fileText = "\(files) \(files == 1 ? "file" : "files")"
        return pages == 0 ? fileText : fileText + " · " + pageText
    }

    private func footer(_ quick: QuickOpenModel) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(quick.isLoading ? "Listing files…" : Self.countLine(files: quick.root == nil ? nil : quick.results.count, pages: quick.pageResults.count))
                .contentTransition(.numericText(value: Double(quick.results.count + quick.pageResults.count)))
            Spacer()
            KeyCap("↑"); KeyCap("↓"); Text("move")
            Text("·").foregroundStyle(.quaternary)
            KeyCap("↩"); Text("open")
            Text("·").foregroundStyle(.quaternary)
            KeyCap("esc"); Text("close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s + 1)
        .animation(DS.Motion.smooth, value: quick.results.count + quick.pageResults.count)
    }

    private func open() {
        model.quickOpen.submit()
    }
}

/// A file's open notes, as the tree shows them: overlapping dots in the notes' colours and the count, orange when
/// something needs attention.
struct NoteMarkBadge: View {
    let mark: NoteMark

    var body: some View {
        HStack(spacing: 3) {
            HStack(spacing: -3) {
                ForEach(Array(mark.colors.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(Color(nsColor: Theme.color(for: color)))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                }
            }
            Text("\(mark.count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(mark.needsAttention ? Color.orange : Color.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background((mark.needsAttention ? Color.orange.opacity(0.18) : Color.primary.opacity(0.07)), in: Capsule())
        .help("\(mark.count) open note\(mark.count == 1 ? "" : "s")\(mark.needsAttention ? ", needs attention" : "")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mark.count) open note\(mark.count == 1 ? "" : "s")")
    }
}
