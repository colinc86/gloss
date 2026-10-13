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
            if let document = session.document, model.notesPanel.allGroups.contains(where: { $0.document.id == document.id }) {
                HStack {
                    Text(session.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    IterationMenu(document: document)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            if let iteration = model.iterations.viewedIteration(for: session) {
                IterationBanner(session: session, iteration: iteration)
                    .transition((AnyTransition.move(edge: .top).combined(with: .opacity)).calmed)
            }
            if let banner = session.banner {
                BannerView(banner: banner, session: session)
                    .transition((AnyTransition.move(edge: .top).combined(with: .opacity)).calmed)
            }
            RefinementNotice(session: session)
            content
                // A native sibling above the paths keeps the document and its glass card in the right order.
                .background(ReviewOverlay(model: model, session: session))
            Divider()
            StatusBar(session: session)
        }
        .animation(DS.Motion.smooth, value: session.banner)
        .animation(DS.Motion.smooth, value: model.review.isActive)
        // The notes panel's link follows whichever view of the document is in front.
        .onChange(of: session.noteGeometry.map(ObjectIdentifier.init), initial: true) {
            model.noteLink.attach(session.noteGeometry)
        }
        .onDisappear {
            if let geometry = session.noteGeometry { model.noteLink.detach(geometry) }
        }
        // The note under the pointer on the page draws its path strong, as hovering its card does.
        .onChange(of: session.textController?.peek?.id) { _, id in model.noteLink.peekedNoteID = id }
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
            ContentUnavailableView {
                Label(session.fileName, systemImage: icon(for: kind))
            } description: {
                Text(Self.unsupportedMessage(hostID: session.hostID, isPastIteration: session.pastIteration != nil))
            } actions: {
                // A button as well as ⌘⇧N: the shortcut is never the only way to a note.
                if session.pastIteration == nil {
                    Button("Add Note to File") { session.beginNote() }
                }
            }
                .notePopover(session: session)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't open \(session.fileName)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await session.retryOpen() } }
                    .buttonStyle(.glass)
            }
        }
    }

    /// Why there is nothing to show, by where the file is: it said "on a remote host" for an earlier iteration of a
    /// file on this Mac and for a pull request's file too.
    nonisolated static func unsupportedMessage(hostID: HostID, isPastIteration: Bool) -> String {
        if isPastIteration { return "Gloss can't show an earlier version of this kind of file." }
        let notes = " A note on the whole file still works."
        if hostID.isVirtual { return "Gloss has no viewer for this kind of file." + notes }
        return hostID == .local ? "Gloss has no viewer for this kind of file." + notes : "Gloss has no viewer for this kind of file on a remote host yet." + notes
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
        let style = Self.style(banner, session: session)
        Notice(kind: style.kind, symbol: style.symbol, title: style.title, detail: style.detail, pulses: banner == .reanchoring) {
            switch banner {
            case .externalChange:
                Button("Keep Mine") { session.dismissBanner() }
                Button("Reload") { Task { await session.reloadFromDisk() } }
                    .buttonStyle(.glassProminent)
            case .decodedAsLatin1 where !session.isReadOnly:
                Button("Convert to UTF-8") { session.convertToUTF8() }
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

    static func style(_ banner: DocumentSession.Banner, session: DocumentSession) -> (kind: NoticeKind, symbol: String, title: String, detail: String) {
        switch banner {
        case .externalChange:
            (.warning, "exclamationmark.arrow.triangle.2.circlepath", "Changed on disk", "The file was saved elsewhere while you have unsaved edits here.")
        case .decodedAsLatin1:
            (.info, "textformat.abc", "Shown as \(session.textEncoding.displayName)", "This file isn't valid UTF-8, so some characters may look wrong. It's saved back as \(session.textEncoding.displayName), byte for byte where unchanged.")
        case .readOnlyLargeFile:
            (.info, "lock.doc", "Read-only", "Files over 2 MB open read-only.")
        case .tooLarge:
            (.info, "doc.questionmark", "Too large to show", "Files over 50 MB aren't shown in the text viewer.")
        case .reanchoring:
            (.mode, "scope", "Placing a note", "Select its new range, then click Add Note.")
        case .deletedOnDisk:
            switch session.hostID {
            case .github: (.warning, "arrow.triangle.pull", "No longer in this pull request", "A newer push took this file out. Its notes stay until you delete them.")
            case .atlassian: (.warning, "questionmark.folder", "No longer available", "The issue or page is gone, or the key can't see it any more. Its notes stay until you delete them.")
            default: (.warning, "trash", "Deleted on disk", "This file is no longer at its path. Its notes stay until you delete them.")
            }
        case .resourceUpdated:
            (.info, "arrow.triangle.2.circlepath", session.resourceUpdateSummary ?? (session.hostID == .atlassian ? "Updated in Jira or Confluence" : "Pull request updated"),
             session.hostID == .atlassian ? "The ticket or page changed at its source; this document reloaded and its notes followed." : "Something changed on GitHub; this document reloaded and its notes followed.")
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
            if !session.notes.isEmpty, session.noteGeometry != nil {
                NoteLinkToggles()
                    .transition(.opacity)
            }
            changedLines
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
            if session.hostID != .local, !session.hostID.isVirtual, let host = model.hosts.entry(for: session.hostID)?.name {
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
            if session.hostID == .atlassian, let reference = AtlassianPath(session.path) {
                switch reference {
                case .jiraIssue(let project, let key):
                    Label("Jira · \(project)", systemImage: "ticket")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .contextMenu {
                            if let site = model.integrations.atlassian?.site {
                                Button("Open \(key) in Jira") { NSWorkspace.shared.open(site.appendingPathComponent("browse/\(key)")) }
                                Button("Copy Issue URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(site.appendingPathComponent("browse/\(key)").absoluteString, forType: .string)
                                    model.flashCopied("URL copied")
                                }
                            }
                        }
                case .confluencePage(let space, _, _, _):
                    Label("Confluence · \(space)", systemImage: "doc.text")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .contextMenu {
                            if let url = model.webURL(hostID: .atlassian, path: session.path) {
                                Button("Open in Confluence") { NSWorkspace.shared.open(url) }
                                Button("Copy Page URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    model.flashCopied("URL copied")
                                }
                            }
                        }
                default:
                    EmptyView()
                }
                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
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
            // A pull request's number is in its label already; the crumbs start below the root. A Confluence page's
            // folder is its id and its document already carries the title, so only the document shows.
            let crumbs = session.kind == .web ? [] : session.hostID == .github ? Array(segments.dropFirst())
                : session.hostID == .atlassian ? Array(segments.suffix(1)) : segments
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
                Text(lines > 1 ? "\(lines.counted("line")) · \(length.counted("character"))" : length.counted("character"))
                    .foregroundStyle(.primary)
                    .help("Ln \(position.start.line), Col \(position.start.col) – Ln \(position.end.line), Col \(position.end.col)")
            } else {
                Text("Ln \(position.start.line), Col \(position.start.col)")
                    .help(controller.lineIndex.lineCount.counted("line"))
            }
        }
        .contentTransition(.numericText())
        .animation(DS.Motion.snappy, value: length)
    }

    // MARK: Notes

    /// This file's open notes as coloured dots and a count; opens the notes panel.
    @ViewBuilder
    private var openNotes: some View {
        let open = session.notes.filter(NotesPanelModel.isOpen)
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

    /// A pull request file's hunks: how many, "2 of 7" while stepping, and the steps themselves.
    @ViewBuilder
    private var changedLines: some View {
        let hunks = session.changeHunks
        if session.changesUnknown {
            Label("Changes not shown", systemImage: "plus.forwardslash.minus")
                .foregroundStyle(.secondary)
                .help("Too large for GitHub to show changes: it sends no line-by-line patch for this file")
                .transition(.opacity)
        } else if !hunks.isEmpty {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "plus.forwardslash.minus")
                    .foregroundStyle(.green)
                Group {
                    if let position = session.changePosition {
                        Text("\(position.index) of \(position.count)")
                            .contentTransition(.numericText(value: Double(position.index)))
                    } else {
                        Text(hunks.count == 1 ? "1 change" : "\(hunks.count) changes")
                    }
                }
                .monospacedDigit()
                HStack(spacing: 0) {
                    StepButton(symbol: "chevron.up", help: "Previous Change (⌥⌘↑)") { session.stepChange(forward: false) }
                    StepButton(symbol: "chevron.down", help: "Next Change (⌥⌘↓)") { session.stepChange(forward: true) }
                }
            }
            .help("Lines this pull request added or rewrote are tinted; a red line marks where lines were removed")
            .transition(.opacity)
            .animation(DS.Motion.snappy, value: session.changePosition?.index)
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
                            .transition(AddNoteButton.transition(emergingFrom: AddNoteButton.emergence(for: local, in: proxy.size)).calmed)
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
            EarlierNotesLayer(session: session)
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
    static let size = CGSize(width: 148, height: 30)
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
                Text("⌘↩")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: Self.size.height)
        }
        .buttonStyle(.glass)
        .scaleEffect(hovering ? 1.04 : 1, anchor: .bottomTrailing)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help("Attach a \(color.rawValue) note to the selection (⌘↩)")
        .accessibilityLabel("Add note")
        .accessibilityIdentifier("addNoteButton")
    }

    /// Grows out of the selected line to where it rests, as if it unfolded from the text; leaves the same way,
    /// quickly, so it never lingers over the text. `anchor` is the line's point in the button's own unit space.
    static func transition(emergingFrom anchor: UnitPoint) -> AnyTransition {
        // Reduce Motion: a plain fade, nothing growing.
        if Motion.isReduced { return .opacity.animation(DS.Motion.smooth) }
        return .asymmetric(
            insertion: .scale(scale: 0.2, anchor: anchor).combined(with: .opacity).animation(DS.Motion.bouncy),
            removal: .scale(scale: 0.6, anchor: anchor).combined(with: .opacity).animation(.easeOut(duration: 0.1))
        )
    }

    /// Where the selected line meets the button, in the button's unit space (outside 0...1 when it is beyond the
    /// button's edge): the edge of the selection the button sits against, under the button's middle (or the
    /// selection's, when the selection is narrower), so the button grows straight out of the text.
    static func emergence(for selection: CGRect, in bounds: CGSize) -> UnitPoint {
        let center = placement(for: selection, in: bounds)
        let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        let lineY = frame.midY < selection.minY ? selection.minY : selection.maxY
        let lineX = min(max(frame.midX, selection.minX), selection.maxX)
        return UnitPoint(x: (lineX - frame.minX) / frame.width, y: (lineY - frame.minY) / frame.height)
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

/// A click on an earlier notes' mark in the gutter lists that spot's notes from earlier iterations in a card beside it:
/// newest first, each with what was asked, the agent's last word and how it ended, to look at where it was taken or
/// bring forward.
private struct EarlierNotesLayer: View {
    @Environment(AppModel.self) private var model
    let session: DocumentSession
    @State private var cardHeight: CGFloat = 160
    static let width: CGFloat = 340

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if let controller = session.textController, let shown = controller.earlierPeek,
                   let rect = controller.rect(for: shown.range)?.offsetBy(dx: -origin.x, dy: -origin.y) {
                    let notes = shown.ids.compactMap { id in session.earlierNotes.first { $0.note.id == id }?.note }
                    let below = rect.maxY + 6 + cardHeight <= proxy.size.height
                    let x = min(max(DS.Space.s, rect.minX), proxy.size.width - Self.width - DS.Space.s)
                    let y = below ? rect.maxY + 6 : max(DS.Space.s, rect.minY - 6 - cardHeight)
                    EarlierNotesCard(notes: notes, session: session) { controller.earlierPeek = nil }
                        .frame(width: Self.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                        .offset(x: x, y: y)
                        .transition((AnyTransition.scale(scale: 0.94, anchor: below ? .top : .bottom).combined(with: .opacity)).calmed)
                        .id(shown.ids)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(DS.Motion.snappy, value: session.textController?.earlierPeek?.ids)
        }
    }
}

private struct EarlierNotesCard: View {
    @Environment(AppModel.self) private var model
    let notes: [Note]
    let session: DocumentSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Label(notes.count == 1 ? "1 earlier note here" : "\(notes.count) earlier notes here", systemImage: "square.stack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.xs)
                InlineIconButton(title: "Close", symbol: "xmark", emphasized: false, action: close)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(notes) { note in
                        if note.id != notes.first?.id { Divider() }
                        entry(note)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 320)
        }
        .padding(DS.Space.m)
        .readableGlass(in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Earlier notes here")
    }

    private func entry(_ note: Note) -> some View {
        let tint = Color(nsColor: Theme.color(for: note.color))
        return HStack(alignment: .top, spacing: DS.Space.m) {
            Capsule().fill(tint.gradient).frame(width: 3)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Text("Iteration \(note.iteration) · \(note.createdAt.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: DS.Space.xs)
                    NoteCard.badge(note)
                }
                Text(NoteCard.styledBody(note.body))
                    .font(.callout)
                    .lineLimit(4)
                    .textSelection(.enabled)
                if let latest = NoteThread(comment: note.body, messages: model.notesPanel.messages(for: note.id)).latest, latest.speaker == .agent {
                    AgentMessageBubble(message: latest.text, asks: false, agent: latest.agent ?? note.resolveAgent)
                        .frame(maxHeight: 100)
                }
                HStack(spacing: DS.Space.s) {
                    Button("Show in Iteration \(note.iteration)") { model.showEarlierNote(note, in: session) }
                    if let document = session.document {
                        Button("Bring Forward") {
                            close()
                            Task { await model.iterations.bringForward(note, in: document) }
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
                    NoteCard.badge(note)
                }
                Text((try? AttributedString(markdown: note.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(note.body))
                    .font(.callout)
                    .lineLimit(6)
                // The thread's latest word from the agent, as the card shows it.
                if let latest = NoteThread(comment: note.body, messages: model.notesPanel.messages(for: note.id)).latest, latest.speaker == .agent {
                    // Who spoke, then the words, as the card's bubble has it; orange while the question waits on you.
                    let waiting = latest.asks && note.waitingOnUser
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(AgentMessageBubble.heading(agent: latest.agent ?? note.author ?? note.resolveAgent))
                            .font(.caption2.weight(.semibold))
                        Text(latest.text)
                            .font(.caption)
                            .lineLimit(3)
                    }
                    .foregroundStyle(waiting ? Color.orange : Color.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AgentMessageBubble.spoken(agent: latest.agent ?? note.author ?? note.resolveAgent, message: latest.text, waiting: waiting))
                }
                HStack(spacing: DS.Space.xxs) {
                    // A draft's next step is sending it, so Send leads, as on the panel's cards.
                    if note.state == .draft || note.state == .sent, let target = model.send.lastTarget, model.send.isTargetAvailable, model.isInSendScope(note) {
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
}

/// Link and paths, after the note stepper: the notes panel following the page, and curves from each note on the
/// page to its card. Off shows the glyph struck through; paths need link, so its toggle waits for it.
private struct NoteLinkToggles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let link = model.noteLink
        HStack(spacing: 0) {
            LinkToggle(symbol: "link", label: "Follow Page in Notes Panel", isOn: link.isLinked,
                       help: link.isLinked ? "Stop following the page in the notes panel" : "Follow the page in the notes panel") {
                model.setNotesLinked(!link.isLinked)
            }
            LinkToggle(symbol: "point.bottomleft.forward.to.point.topright.scurvepath", label: "Show Paths to Notes", isOn: link.drawsPaths,
                       help: !link.isLinked ? "Follow the page in the notes panel to draw paths to notes"
                           : link.showsPaths ? "Hide the paths from notes to their cards" : "Draw paths from notes to their cards") {
                link.showsPaths.toggle()
            }
            .disabled(!link.isLinked)
        }
        .animation(DS.Motion.snappy, value: link.isLinked)
        .animation(DS.Motion.snappy, value: link.showsPaths)
    }
}

/// A status bar toggle in the stepper's style: accent when on, struck through when off.
private struct LinkToggle: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(hovering && isEnabled ? .primary : .secondary))
                .overlay {
                    if !isOn {
                        // The struck-through glyph: SF Symbols has no unlinked or broken path.
                        Capsule()
                            .frame(width: 1.25, height: 15)
                            .rotationEffect(.degrees(-45))
                            .foregroundStyle(hovering && isEnabled ? .primary : .secondary)
                            .transition(.scale(scale: 0.2).combined(with: .opacity).calmed)
                    }
                }
                .frame(width: 18, height: 16)
                .background(isOn ? Color.accentColor.opacity(0.14) : hovering && isEnabled ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// One step of a stepper: a small chevron that brightens under the pointer.
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
