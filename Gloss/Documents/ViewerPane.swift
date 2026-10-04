import Core
import Integrations
import SwiftUI
import UniformTypeIdentifiers
import Viewers

struct ViewerPane: View {
    @Environment(AppModel.self) private var model
    let session: DocumentSession

    var body: some View {
        VStack(spacing: 0) {
            if let banner = session.banner {
                BannerView(banner: banner, session: session)
                    .transition((AnyTransition.move(edge: .top).combined(with: .opacity)).calmed)
            }
            content
            Divider()
            StatusBar(session: session)
        }
        .animation(DS.Motion.smooth, value: session.banner)
        .sheet(isPresented: Binding(get: { session.isGoToLinePresented }, set: { session.isGoToLinePresented = $0 })) {
            GoToLineSheet(lineCount: session.textController.map { controller in
                // A trailing newline starts an empty line that is not a real one.
                let count = controller.lineIndex.lineCount
                return count > 1 && controller.lineIndex.contentRange(ofLine: count).length == 0 ? count - 1 : count
            } ?? 1, lineText: { line in
                guard let controller = session.textController else { return nil }
                return controller.text.line(line, index: controller.lineIndex)
            }, language: GrammarCatalog.languageName(forPath: session.path)) { line, column in
                session.isGoToLinePresented = false
                session.goTo(line: line, column: column)
            } onCancel: {
                session.isGoToLinePresented = false
            }
        }
        .sheet(isPresented: Binding(get: { session.conflict != nil }, set: { if !$0 { session.conflict = nil } })) {
            if let conflict = session.conflict {
                ConflictSheet(session: session, conflict: conflict)
            }
        }
        .alert("Error", isPresented: Binding(get: { session.lastError != nil }, set: { if !$0 { session.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(session.lastError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .loading:
            LoadingDocumentView(fileName: session.fileName, path: session.path,
                                host: session.hostID == .local ? nil : model.hosts.entry(for: session.hostID)?.name)
        case .text(let controller):
            Group {
                if let markdown = session.markdown {
                    MarkdownViewerView(controller: markdown)
                } else if let html = session.html {
                    HTMLViewerView(controller: html, browser: model.browser,
                                   via: session.kind == .web && session.hostID != .web ? model.hosts.entry(for: session.hostID)?.name : nil)
                } else {
                    TextEditorView(controller: controller)
                }
            }
                .notePopover(session: session)
        case .image(let controller):
            ImageViewerPane(controller: controller)
                .id(ObjectIdentifier(controller))
                .notePopover(session: session)
        case .pdf(let controller):
            PDFViewerPane(controller: controller)
                .id(ObjectIdentifier(controller))
                .notePopover(session: session)
        case .csv(let controller):
            CSVGridPane(controller: controller)
                .id(ObjectIdentifier(controller))
                .notePopover(session: session)
        case .quickLook(let url):
            QuickLookView(url: url)
                .notePopover(session: session)
        case .unsupported(let kind):
            ContentUnavailableView(
                session.fileName,
                systemImage: icon(for: kind),
                description: Text("No viewer for this file on a remote host yet. Whole-file notes still work (⌘⇧N).")
            )
                .notePopover(session: session)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not open \(session.fileName)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await session.retryOpen() } }
                    .buttonStyle(.glass)
            }
        }
    }

    private func icon(for kind: DocumentKind) -> String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .csv: "tablecells"
        case .web: "globe"
        default: "doc"
        }
    }
}

private struct BannerView: View {
    @Environment(AppModel.self) private var model
    let banner: DocumentSession.Banner
    let session: DocumentSession

    var body: some View {
        let style = Self.style(banner)
        Notice(kind: style.kind, symbol: style.symbol, title: style.title, detail: style.detail, pulses: banner == .reanchoring) {
            switch banner {
            case .externalChange:
                Button("Keep Mine") { session.dismissBanner() }
                Button("Reload") { Task { await session.reloadFromDisk() } }
                    .buttonStyle(.glassProminent)
            case .reanchoring:
                Button("Cancel") { session.cancelReanchor() }
            case .deletedOnDisk:
                Button("Close") {
                    // The editor may hold the only copy of the text now; closing it unsaved must be a choice.
                    if session.isDirty, !Self.confirmCloseUnsaved(session) { return }
                    model.closeDocument(session)
                }
                if session.textController != nil, !session.isReadOnly {
                    Button("Save Here") { Task { await session.putBack() } }
                        .buttonStyle(.glassProminent)
                        .help("Write the text shown here back to \(session.path)")
                }
            default:
                InlineIconButton(title: "Dismiss", symbol: "xmark", emphasized: true) { session.dismissBanner() }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.xs)
    }

    /// Asks before dropping unsaved edits to a file that is gone: Save Here writes them back first.
    static func confirmCloseUnsaved(_ session: DocumentSession) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(session.fileName) without saving?"
        alert.informativeText = "The file was deleted on disk, so your edits exist only here."
        alert.addButton(withTitle: "Save Here")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Without Saving").hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await session.putBack() }
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    static func style(_ banner: DocumentSession.Banner) -> (kind: NoticeKind, symbol: String, title: String, detail: String) {
        switch banner {
        case .externalChange:
            (.warning, "exclamationmark.arrow.triangle.2.circlepath", "Changed on disk", "The file was saved elsewhere while you have unsaved edits here.")
        case .decodedAsLatin1:
            (.info, "textformat.abc", "Shown as Latin-1", "This file isn't valid UTF-8, so some characters may look wrong.")
        case .readOnlyLargeFile:
            (.info, "lock.doc", "Read-only", "Files over 2 MB open read-only.")
        case .tooLarge:
            (.info, "doc.questionmark", "Too large to show", "Files over 50 MB aren't shown in the text viewer.")
        case .reanchoring:
            (.mode, "scope", "Placing a note", "Select its new range, then click Add Note.")
        case .deletedOnDisk:
            (.warning, "trash", "Deleted on disk", "This file is no longer at its path. Its notes stay until you delete them.")
        }
    }
}

/// The strip under the viewer: where the file lives (a breadcrumb that reveals each folder in the tree), what is
/// selected, this file's open notes, and what kind of file it is.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model
    let session: DocumentSession

    var body: some View {
        HStack(spacing: DS.Space.m) {
            if session.isDirty {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
                    .transition((AnyTransition.scale.combined(with: .opacity)).calmed)
            }
            breadcrumb
            Spacer(minLength: DS.Space.m)
            if let controller = session.textController {
                selectionSummary(controller)
            }
            openNotes
            if session.isReadOnly {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .help(session.readOnlyReason)
            }
            Text(languageName)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
        .animation(DS.Motion.snappy, value: session.isDirty)
    }

    // MARK: Breadcrumb

    /// Folders from the explorer root down to the file; outside every root, the last three components.
    private var segments: [(name: String, path: String)] {
        let path = session.path
        let root = model.explorer.tabs
            .filter { $0.hostID == session.hostID }
            .map { ExplorerModel.aliasFree($0.path) }
            .filter { ExplorerModel.aliasFree(path).hasPrefix($0 == "/" ? "/" : $0 + "/") }
            .max { $0.count < $1.count }
        var components: [(String, String)] = []
        var current = path
        while current != "/" && !current.isEmpty {
            components.insert(((current as NSString).lastPathComponent, current), at: 0)
            if let root, ExplorerModel.aliasFree(current) == root { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return root == nil ? Array(components.suffix(3)) : components
    }

    private var breadcrumb: some View {
        HStack(spacing: DS.Space.xxs) {
            if session.hostID != .local, session.hostID != .github, let host = model.hosts.entry(for: session.hostID)?.name {
                Label(session.kind == .web ? "via \(host)" : host, systemImage: "network")
                    .labelStyle(.titleAndIcon)
                    .padding(.trailing, DS.Space.xs)
            }
            if session.hostID == .github, let pull = PullRequestPath(session.path) {
                // The pull request itself, where the crumbs below it live.
                Label("\(pull.repository) #\(pull.number)", systemImage: "arrow.triangle.pull")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .help("Pull request \(pull.webURL.absoluteString)")
                    .contextMenu {
                        Button("Open on GitHub") { NSWorkspace.shared.open(pull.webURL) }
                        Button("Copy Pull Request URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pull.webURL.absoluteString, forType: .string)
                            model.flashCopied("URL copied")
                        }
                    }
                if !pull.rest.isEmpty {
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                }
            }
            if session.kind == .web {
                // A page's address, not folders: nothing here to reveal in the explorer.
                Label(session.fileName, systemImage: "globe")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .help(session.path)
                    .contextMenu {
                        Button("Copy Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.path, forType: .string)
                            model.flashCopied("Address copied")
                        }
                    }
            }
            // A pull request's number is in its label already; the crumbs start below the root.
            let crumbs = session.kind == .web ? [] : (session.hostID == .github ? Array(segments.dropFirst()) : segments)
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                }
                let isFile = index == crumbs.count - 1
                BreadcrumbSegment(title: segment.name, isCurrent: isFile) {
                    Task { _ = await model.explorer.reveal(hostID: session.hostID, path: segment.path) }
                }
                .help(isFile ? "Reveal \(segment.name) in the explorer" : "Reveal \(segment.path) in the explorer")
                .contextMenu { segmentMenu(path: segment.path, isFile: isFile) }
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// Right-click on a breadcrumb segment, as on Finder's path bar: what you'd do with that file or folder outside
    /// this app.
    @ViewBuilder
    private func segmentMenu(path: String, isFile: Bool) -> some View {
        if session.hostID == .local {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            if isFile {
                Button("Open With Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            Divider()
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
            model.flashCopied("Path copied")
        }
    }

    // MARK: Selection

    @ViewBuilder
    private func selectionSummary(_ controller: TextEditorController) -> some View {
        let position = controller.selectionPosition
        let length = controller.selection.length
        Group {
            if length > 0 {
                let lines = position.end.line - position.start.line + 1
                Text(lines > 1 ? "\(lines) lines · \(length) characters" : "\(length) characters")
                    .foregroundStyle(.primary)
                    .help("Ln \(position.start.line), Col \(position.start.col) – Ln \(position.end.line), Col \(position.end.col)")
            } else {
                Text("Ln \(position.start.line), Col \(position.start.col)")
                    .help("\(controller.lineIndex.lineCount) lines")
            }
        }
        .contentTransition(.numericText())
        .animation(DS.Motion.snappy, value: length)
    }

    // MARK: Notes

    /// This file's open notes as coloured dots and a count; opens the notes panel.
    @ViewBuilder
    private var openNotes: some View {
        let open = session.notes.filter { $0.state != .resolved || $0.resolveOutcome == .needsInput }
        if !open.isEmpty {
            Button {
                model.showNotesPanel = true
            } label: {
                HStack(spacing: DS.Space.xs) {
                    HStack(spacing: -2) {
                        ForEach(Array(Set(open.map(\.color))).sorted { $0.rawValue < $1.rawValue }.prefix(3), id: \.self) { color in
                            Circle()
                                .fill(Color(nsColor: Theme.color(for: color)))
                                .frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        }
                    }
                    // "2 of 3" while stepping (⌘'), otherwise how many there are.
                    Group {
                        if let step = session.stepPosition {
                            Text("\(step.index) of \(step.count)")
                                .contentTransition(.numericText(value: Double(step.index)))
                        } else {
                            Text(open.count == 1 ? "1 note" : "\(open.count) notes")
                                .contentTransition(.numericText(value: Double(open.count)))
                        }
                    }
                    .monospacedDigit()
                }
            }
            .buttonStyle(PressableStyle())
            .help("Show this file's notes")
            .transition((AnyTransition.scale(scale: 0.8).combined(with: .opacity)).calmed)
            .animation(DS.Motion.smooth, value: open.count)
            .animation(DS.Motion.snappy, value: session.stepPosition?.index)
            if !session.steppableNotes.isEmpty {
                NoteStepper()
                    .transition(.opacity)
            }
        }
    }

    // MARK: Kind

    private var languageName: String {
        let names = ["javascript": "JavaScript", "typescript": "TypeScript", "tsx": "TSX", "json": "JSON", "yaml": "YAML",
                     "toml": "TOML", "c": "C", "bash": "Shell", "markdown": "Markdown"]
        if session.kind == .web { return "Web" }
        if ["diff", "patch"].contains((session.path as NSString).pathExtension.lowercased()) { return "Diff" }
        if HTMLViewerController.handles(path: session.path) { return "HTML" }
        if let grammar = GrammarCatalog.languageName(forPath: session.path) { return names[grammar] ?? grammar.capitalized }
        return switch session.kind {
        case .csv: "CSV"
        case .pdf: "PDF"
        default: session.kind.rawValue.capitalized
        }
    }
}

/// One breadcrumb step: the file reads as primary, folders as secondary, each brightening under the pointer.
private struct BreadcrumbSegment: View {
    let title: String
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(isCurrent || hovering ? .primary : .secondary)
                .fontWeight(isCurrent ? .medium : .regular)
                .padding(.horizontal, DS.Space.xs)
                .padding(.vertical, 1)
                .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
    }
}

/// Presents the note popover at `anchorRect`, which providers give in top-left window coordinates, and floats an
/// "Add Note" button next to whatever is selected, so a note never needs the keyboard shortcut.
private struct NotePopoverHost: ViewModifier {
    @Environment(AppModel.self) private var model
    let session: DocumentSession

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let selection = session.selectionAffordanceRect
                ZStack {
                    if let selection {
                        let local = selection.offsetBy(dx: -origin.x, dy: -origin.y)
                        AddNoteButton(color: session.lastUsedColor, action: { session.beginNote() })
                            .position(AddNoteButton.placement(for: local, in: proxy.size))
                            .transition(AddNoteButton.transition.calmed)
                            // Follows a growing selection smoothly instead of jumping.
                            .animation(DS.Motion.smooth, value: local)
                    }
                }
                .animation(DS.Motion.bouncy, value: selection == nil)
            }
        }
        .overlay {
            NotePeekLayer(session: session)
        }
        .overlay {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let rect = (session.noteEditor?.anchorRect ?? .zero).offsetBy(dx: -origin.x, dy: -origin.y)
                Color.clear
                    .popover(item: Binding(get: { session.noteEditor }, set: { session.noteEditor = $0 }), attachmentAnchor: .rect(.rect(rect)), arrowEdge: .bottom) { state in
                        NotePopover(
                            state: state,
                            onSave: { edited in Task { await session.commitNote(edited) } },
                            // The same undoable delete as the panel's (toast and Edit › Undo), not a permanent one.
                            onDelete: { id in
                                session.noteEditor = nil
                                Task { await model.notesPanel.delete(id) }
                            },
                            onCancel: { session.noteEditor = nil },
                            language: GrammarCatalog.languageName(forPath: session.path)
                        )
                    }
            }
            .allowsHitTesting(false)
        }
    }
}

/// The floating pill. Glass on macOS 26, sized to its label; placed above the selection's trailing edge, or
/// below it when there is no room above.
struct AddNoteButton: View {
    /// The colour the new note will start with (the last one used), shown so the result is never a surprise.
    var color: NoteColor = .yellow
    let action: () -> Void
    static let size = CGSize(width: 118, height: 30)
    @State private var hovering = false

    var body: some View {
        let tint = Color(nsColor: Theme.color(for: color))
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                ZStack {
                    Circle().fill(tint.gradient).frame(width: 14, height: 14)
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.black.opacity(0.7))
                }
                .shadow(color: tint.opacity(hovering ? 0.7 : 0.35), radius: hovering ? 5 : 3)
                Text("Add Note")
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: Self.size.height)
        }
        .buttonStyle(.glass)
        .scaleEffect(hovering ? 1.04 : 1, anchor: .bottomTrailing)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help("Attach a \(color.rawValue) note to the selection (⌘⇧N)")
        .accessibilityLabel("Add note")
        .accessibilityIdentifier("addNoteButton")
    }

    /// Springs out of the selection's corner; leaves quickly so it never lingers over the text.
    static var transition: AnyTransition {
        // Reduce Motion: a plain fade, no spring out of the corner.
        if Motion.isReduced { return .opacity.animation(DS.Motion.smooth) }
        return .asymmetric(
            insertion: .scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity).animation(DS.Motion.bouncy),
            removal: .scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity).animation(.easeOut(duration: 0.1))
        )
    }

    /// Center point for `.position`, kept inside `bounds`.
    static func placement(for selection: CGRect, in bounds: CGSize) -> CGPoint {
        let gap: CGFloat = 8
        var x = selection.maxX - size.width / 2
        var y = selection.minY - gap - size.height / 2
        if y - size.height / 2 < 0 { y = selection.maxY + gap + size.height / 2 }
        x = min(max(x, size.width / 2 + gap), bounds.width - size.width / 2 - gap)
        y = min(max(y, size.height / 2), bounds.height - size.height / 2)
        return CGPoint(x: x, y: y)
    }
}

extension View {
    func notePopover(session: DocumentSession) -> some View {
        modifier(NotePopoverHost(session: session))
    }
}

/// ⌘L: a line, or `line:column`, to jump to in the open text. A palette like Open Quickly: a large field, a live
/// preview of the line you will land on with its neighbours, and where it sits in the file.
struct GoToLineSheet: View {
    let lineCount: Int
    /// The text of a 1-based line, for the preview.
    var lineText: (Int) -> String? = { _ in nil }
    /// The file's language: the preview is the file, so its code keeps the editor's colours.
    var language: String? = nil
    let onGo: (Int, Int?) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    /// Coloured lines by number, filled as the preview reaches them (each one parses its line).
    @State private var coloured: [Int: AttributedString] = [:]

    private var parsed: (line: Int, column: Int?)? { DocumentSession.parseGoToLine(text) }
    /// The line the jump will land on: past the end snaps to the last line.
    private var target: Int? { parsed.map { min($0.line, lineCount) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "arrow.right.to.line")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Line, or line:column", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title2.monospacedDigit())
                    .focused($focused)
                    .onSubmit { go() }
                Text("of \(lineCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Space.l + 2)
            .padding(.vertical, DS.Space.l)
            Divider()
            preview
                .frame(height: 112)
                .animation(DS.Motion.snappy, value: target)
            Divider()
            HStack(spacing: DS.Space.s) {
                Text(hint)
                    .foregroundStyle(text.isEmpty || parsed != nil ? Color.secondary : Color.orange)
                    .contentTransition(.opacity)
                Spacer()
                KeyCap("↩"); Text("go")
                Text("·").foregroundStyle(.quaternary)
                KeyCap("esc"); Text("close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s + 1)
        }
        .frame(width: 460)
        .onAppear { focused = true }
        .task(id: target) {
            guard let target, language != nil else { return }
            for line in max(1, target - 1)...min(lineCount, target + 1) where coloured[line] == nil {
                if let text = lineText(line), let syntax = SyntaxTheme.highlighted(text, language: language) { coloured[line] = syntax }
            }
        }
        .onExitCommand(perform: onCancel)
    }

    private var hint: String {
        if text.isEmpty { return "Type a number; add :column to land on a column" }
        guard let parsed else { return "Use a line number, like 42 or 42:7" }
        if parsed.line > lineCount { return "Past the end, so it goes to the last line, \(lineCount)" }
        return parsed.column.map { "Line \(parsed.line), column \($0)" } ?? "Line \(parsed.line)"
    }

    @ViewBuilder
    private var preview: some View {
        if let target {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(max(1, target - 1)...min(lineCount, target + 1), id: \.self) { line in
                        HStack(spacing: DS.Space.m) {
                            Text("\(line)")
                                .foregroundStyle(line == target ? Color.accentColor : Color.secondary.opacity(0.6))
                                .frame(width: 44, alignment: .trailing)
                            // Neighbours dim by opacity, not grey, so they keep their colours.
                            Group {
                                if let colouredLine = coloured[line] { Text(colouredLine) } else { Text(lineText(line).map { $0.isEmpty ? " " : $0 } ?? " ") }
                            }
                                .foregroundStyle(Color.primary)
                                .opacity(line == target ? 1 : 0.5)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .font(.system(.callout, design: .monospaced))
                        .padding(.vertical, 3)
                        .padding(.trailing, DS.Space.m)
                        .background {
                            if line == target {
                                RoundedRectangle(cornerRadius: DS.Radius.s + 1, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.14))
                            }
                        }
                    }
                }
                // Where the line sits in the file.
                GeometryReader { proxy in
                    let fraction = lineCount > 1 ? CGFloat(target - 1) / CGFloat(lineCount - 1) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(6, proxy.size.width * fraction))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, DS.Space.m)
            }
            .padding(DS.Space.m)
            .transition(.opacity)
        } else {
            VStack(spacing: DS.Space.xs) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("Lines 1–\(lineCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
    }

    private func go() {
        guard let target else { return }
        onGo(target, parsed?.column)
    }
}

/// Hovering highlighted text for a moment shows that note in a small card beside it: its state, the comment, the
/// agent's reply, and quick actions. Moving onto the card keeps it; leaving both lets it go.
private struct NotePeekLayer: View {
    @Environment(AppModel.self) private var model
    let session: DocumentSession
    @State private var cardHeight: CGFloat = 120
    static let width: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if let controller = session.textController, let peek = controller.peek, session.noteEditor == nil,
                   let note = session.notes.first(where: { $0.id == peek.id }),
                   let rect = controller.rect(for: peek.range)?.offsetBy(dx: -origin.x, dy: -origin.y) {
                    let below = rect.maxY + 6 + cardHeight <= proxy.size.height
                    let x = min(max(DS.Space.s, rect.minX), proxy.size.width - Self.width - DS.Space.s)
                    let y = below ? rect.maxY + 6 : max(DS.Space.s, rect.minY - 6 - cardHeight)
                    NotePeekCard(note: note, session: session)
                        .frame(width: Self.width)
                        // Its height is its content's; the colour rail would otherwise stretch it to the pane.
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                        .onHover { controller.isPeekHovered = $0 }
                        .offset(x: x, y: y)
                        .transition((AnyTransition.scale(scale: 0.94, anchor: below ? .top : .bottom).combined(with: .opacity)).calmed)
                        .id(note.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(DS.Motion.snappy, value: session.textController?.peek?.id)
        }
    }
}

private struct NotePeekCard: View {
    @Environment(AppModel.self) private var model
    let note: Note
    let session: DocumentSession

    private var tint: Color { Color(nsColor: Theme.color(for: note.color)) }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Capsule().fill(tint.gradient).frame(width: 3)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Label(note.anchor.summary, systemImage: note.anchor.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: DS.Space.xs)
                    let needsInput = note.state == .resolved && note.resolveOutcome == .needsInput
                    StatusPill(label: needsInput ? "Needs input" : note.state.rawValue.capitalized,
                               symbol: needsInput ? "questionmark.circle.fill" : note.state.style.symbol,
                               tint: needsInput ? .orange : note.state.style.tint)
                }
                Text((try? AttributedString(markdown: note.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(note.body))
                    .font(.callout)
                    .lineLimit(6)
                if let reply = note.resolveMessage, !reply.isEmpty {
                    Label(reply, systemImage: note.resolveOutcome == .needsInput ? "questionmark.bubble" : "checkmark.bubble")
                        .font(.caption)
                        .foregroundStyle(note.resolveOutcome == .needsInput ? Color.orange : Color.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: DS.Space.xxs) {
                    // A draft's next step is sending it, so Send leads, as on the panel's cards.
                    if note.state == .draft || note.state == .sent, let target = model.send.lastTarget {
                        InlineIconButton(title: "Send to \(target.label)", symbol: "paperplane.fill", prominent: true, emphasized: true) {
                            session.textController?.dismissPeek()
                            Task { await model.send(noteIDs: [note.id]) }
                        }
                    }
                    InlineIconButton(title: "Edit", symbol: "pencil", emphasized: true) {
                        session.textController?.dismissPeek()
                        session.editNote(note)
                    }
                    if note.state == .resolved {
                        InlineIconButton(title: "Reopen as draft", symbol: "arrow.counterclockwise", emphasized: true) {
                            Task { await model.notesPanel.reopen(note.id) }
                        }
                    } else {
                        InlineIconButton(title: "Resolve", symbol: "checkmark", emphasized: true) {
                            Task { await model.notesPanel.resolve(note.id) }
                        }
                    }
                    InlineIconButton(title: "Show in notes panel", symbol: "sidebar.right", emphasized: true) {
                        model.showNotesPanel = true
                        model.notesPanel.selectedNoteID = note.id
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(DS.Space.m)
        .readableGlass(in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        .animation(DS.Motion.smooth, value: note.state)
    }
}

/// While a document opens: nothing for the first quarter second (a local file is usually there by then, and a
/// spinner that flashes reads as a glitch), then the file's icon and name with what is happening.
private struct LoadingDocumentView: View {
    let fileName: String
    let path: String
    let host: String?
    @State private var shown = false

    var body: some View {
        VStack(spacing: DS.Space.m) {
            if shown {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (path as NSString).pathExtension) ?? .data))
                    .resizable()
                    .frame(width: 48, height: 48)
                Text(fileName).font(.headline)
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(host.map { "Opening on \($0)…" } ?? "Opening…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(DS.Motion.smooth, value: shown)
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            shown = true
        }
    }
}

/// Previous and next note, beside the status bar's note count: the same steps as ⇧⌘' and ⌘'.
private struct NoteStepper: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            StepButton(symbol: "chevron.up", help: "Previous Note (⇧⌘')") { model.stepNote(forward: false) }
            StepButton(symbol: "chevron.down", help: "Next Note (⌘')") { model.stepNote(forward: true) }
        }
    }

    private struct StepButton: View {
        let symbol: String
        let help: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .frame(width: 16, height: 16)
                    .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .onHover { hovering = $0 }
            .animation(DS.Motion.snappy, value: hovering)
            .help(help)
            .accessibilityLabel(help)
        }
    }
}
