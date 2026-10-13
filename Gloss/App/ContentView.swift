import AppKit
import Core
import Integrations
import SwiftUI
import Viewers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// What the inspector shows. Follows `model.showNotesPanel`, but opening waits until the window has room.
    @State private var panelShown = false
    @State private var window = WindowReference()
    /// The sidebar column in the full layout; the compact one hides it and slides the explorer over instead.
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// The host under the title: an ssh alias, `owner/repo #12`, `Jira · PROJ`, `Confluence · SPACE`, a page's title;
    /// nothing on this Mac.
    static func subtitle(for session: DocumentSession, hosts: HostsModel) -> String {
        switch session.hostID {
        case .local: ""
        // A page's own title, once it has one: its name is its address.
        case .web: session.html?.pageTitle ?? ""
        case .github: PullRequestPath(session.path).map { "\($0.repository) #\($0.number)" } ?? "GitHub"
        case .atlassian:
            switch AtlassianPath(session.path) {
            case .jiraIssue(let project, _)?: "Jira · \(project)"
            case .jiraAttachment(_, let key, _)?: "Jira · \(key)"
            case .confluencePage(let space, _, _, _)?, .confluenceAttachment(let space, _, _, _)?: "Confluence · \(space)"
            default: "Atlassian"
            }
        default: hosts.entry(for: session.hostID)?.name ?? ""
        }
    }

    var body: some View {
        let compact = model.layout.isCompact
        NavigationSplitView(columnVisibility: Binding(
            get: { compact ? .detailOnly : columnVisibility },
            // Compact, the sidebar button and ⌃⌘S slide the explorer over the document instead.
            set: { if compact { model.layout.isExplorerShown.toggle() } else { columnVisibility = $0 } }
        )) {
            Group {
                // One explorer at a time: compact, it lives in the slide-over (its outline view isn't built twice).
                if compact { Color.clear } else { ExplorerSidebar() }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 600)
        } detail: {
            Group {
                if let session = model.activeSession {
                    // An earlier iteration shows in place of the document, from its snapshot (issue #18).
                    let shown = model.iterations.shownSession(for: session)
                    ViewerPane(session: shown)
                        .id(ObjectIdentifier(shown))
                        .navigationTitle(session.fileName)
                        .navigationSubtitle(Self.subtitle(for: session, hosts: model.hosts))
                } else if model.explorer.tabs.isEmpty {
                    WelcomeView()
                } else {
                    EmptyState(
                        symbol: "doc.text.magnifyingglass",
                        title: "Open a file",
                        message: model.selectedRootIsVirtual ? "Pick one in the explorer." : "Pick one in the explorer, or jump straight to it by name."
                    ) {
                        // A pull request, project or space is browsed in the tree; there is no file index to jump through
                        // (Open Quickly still takes an address there, from the menu or ⌘P).
                        if !model.selectedRootIsVirtual {
                            Button {
                                model.presentQuickOpen()
                            } label: {
                                HStack(spacing: DS.Space.s) {
                                    Text("Open Quickly…")
                                    KeyCap("⌘P")
                                }
                            }
                            .controlSize(.large)
                            .buttonStyle(.glass)
                        }
                        if let tab = model.explorer.selectedTab {
                            let work = OpenWorkItem.items(from: model.notesPanel.groups, rootPath: tab.path, hostID: tab.hostID)
                            if !work.isEmpty {
                                OpenWorkList(items: work) { item in
                                    model.openDocument(hostID: item.document.hostID, path: item.document.path)
                                }
                                .padding(.top, DS.Space.xl)
                            }
                        }
                    }
                }
            }
            // The document keeps room of its own: without a minimum, narrowing the window squeezed it to nothing beside
            // the sidebar and the notes panel, and near that limit the split view kept re-dividing the width (#20).
            .frame(minWidth: 360)
            .sheet(item: Binding(get: { model.explorer.fileNameRequest }, set: { model.explorer.fileNameRequest = $0 })) { request in
                FileOperationSheet(request: request) { model.explorer.fileNameRequest = nil }
            }
            .alert("Couldn't Complete the Action", isPresented: Binding(get: { model.explorer.lastError != nil }, set: { if !$0 { model.explorer.lastError = nil } })) {
                Button("OK", role: .cancel) { model.explorer.lastError = nil }
            } message: { Text(model.explorer.lastError ?? "") }
            .overlay(alignment: .leading) {
                if compact { CompactExplorer() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if compact { NotesTray() }
            }
            .safeAreaInset(edge: .bottom) {
                if let move = model.renameRecovery {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rename needs recovery").font(.headline)
                        Text("\(move.from) → \(move.to)").font(.caption).textSelection(.enabled)
                        Button("Retry Rename Recovery") { Task { await model.retryRenameRecovery() } }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toolbar(removing: .title)
            // A page's title, once it has loaded, names it in the explorer's Web section and in Open Quickly.
            .onChange(of: model.activeSession?.html?.pageTitle) { _, title in
                guard let title, let session = model.activeSession, DocumentKindDetector.isWebURL(session.path) else { return }
                model.webPages.setTitle(title, url: session.path, hostID: session.hostID)
            }
            .inspector(isPresented: Binding(get: { panelShown && !compact }, set: { model.showNotesPanel = $0 })) {
                NotesPanel()
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    HistoryButton(direction: .back)
                    HistoryButton(direction: .forward)
                }
                // The title is drawn here rather than by the window, so it can turn into the address bar; the
                // window keeps its title for Mission Control, the Window menu and VoiceOver.
                ToolbarItem(placement: .navigation) {
                    TitleAddressBar()
                }
                .sharedBackgroundVisibility(.hidden)
                // The window's own title used to take the slack; without it the trailing buttons would close up
                // against the title.
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.presentReport()
                    } label: {
                        Label("Report a Bug or Request a Feature", systemImage: "ladybug")
                    }
                    .help("Report a bug or request a feature")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.showNotesPanel.toggle()
                    } label: {
                        Label("Notes", systemImage: "note.text")
                    }
                    .badge(model.notesPanel.draftCount)
                    .help(model.notesPanel.draftCount == 0 ? "Toggle the notes panel (⌘⌥N)" : "Toggle the notes panel (⌘⌥N) · \(model.notesPanel.draftCount) unsent")
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.isReportPresented }, set: { model.isReportPresented = $0 })) {
            ReportSheet()
        }
        .sheet(item: Binding(get: { model.iterations.prompt }, set: { model.iterations.prompt = $0 })) { prompt in
            OpenNotesPromptSheet(prompt: prompt)
        }
        .sheet(isPresented: Binding(get: { model.pullRequestPicker.isPresented }, set: { if !$0 { model.pullRequestPicker.dismiss() } })) {
            OpenPullRequestSheet()
        }
        .sheet(isPresented: Binding(get: { model.atlassianPicker.isPresented }, set: { if !$0 { model.atlassianPicker.dismiss() } })) {
            OpenAtlassianSheet()
        }
        .sheet(isPresented: Binding(get: { model.quickOpen.isPresented }, set: { if !$0 { model.quickOpen.dismiss() } })) {
            QuickOpenSheet()
        }
        .sheet(item: Binding(get: { model.remotePathPrompt }, set: { model.remotePathPrompt = $0 })) { prompt in
            RemotePathSheet(prompt: prompt) { path in
                Task { await model.openRemoteRoot(hostID: prompt.hostID, path: path) }
            }
        }
        // A note or iteration action that failed (resolve, delete, New Iteration…). On the window, not the notes
        // panel: New Iteration is in the menu bar too, and with the panel hidden its alert waited for the panel.
        .alert("Couldn't Complete the Action", isPresented: Binding(get: { model.notesPanel.lastError != nil }, set: { if !$0 { model.notesPanel.lastError = nil } })) {
            Button("OK", role: .cancel) { model.notesPanel.lastError = nil }
        } message: { Text(model.notesPanel.lastError ?? "") }
        .alert("Notes Are Temporary This Session", isPresented: Binding(get: { model.databaseFailure != nil }, set: { if !$0 { model.databaseFailure = nil } })) {
            Button("OK", role: .cancel) {}
            Button("Show Database in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AppDatabase.defaultURL.deletingLastPathComponent()])
            }
        } message: {
            Text(model.databaseFailure ?? "")
        }
        .alert("Open a File from a Link?", isPresented: Binding(get: { model.pendingLinkOpen != nil }, set: { if !$0 { model.pendingLinkOpen = nil } }), presenting: model.pendingLinkOpen) { pending in
            Button("Cancel", role: .cancel) {}
            Button("Open") {
                Task { await URLRouter.open(hostID: pending.hostID, path: pending.path, line: pending.line, model: model) }
            }
        } message: { pending in
            Text((pending.hostName.map { "A link asked to connect to \($0) and open \(pending.path)." } ?? "A link asked to open \(pending.path).")
                 + " Open it only if you followed this link yourself.")
        }
        .dropToOpen()
        // Window notifications sit above the document's floating Review card.
        .background(WindowHUDOverlay(model: model, panelShown: panelShown, openSettings: { openSettings() }))
        // The dot in the close button whenever any open document has unsaved edits, not only the visible one.
        .background(WindowEditedMarker(isEdited: !model.unsavedSessions.isEmpty))
        .background(WindowReader(reference: window))
        .onChange(of: model.showNotesPanel, initial: true) { _, show in
            syncPanel(show)
            // The paths from notes to cards need the side panel; the compact tray has none to draw to.
            model.noteLink.isPanelShown = show && !model.layout.isCompact
        }
        // Full or compact follows the window's width (and Settings › General › Layout).
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            model.layout.height = size.height
            model.updateLayout(width: size.width)
        }
        .onChange(of: model.settings.layoutMode) { _, _ in model.updateLayout() }
        .onChange(of: model.settings.compactBelow) { _, _ in model.updateLayout() }
        .onChange(of: model.layout.isCompact) { _, isCompact in
            model.noteLink.isPanelShown = model.showNotesPanel && !isCompact
            // Compact closes the inspector; back to full, it opens as it would, making room first.
            syncPanel(model.showNotesPanel)
        }
        .onChange(of: window.isAttached) { _, _ in
            model.mainWindow = window.window
            model.openMainWindow = { [openWindow] in openWindow(id: "main") }
            syncPanel(model.showNotesPanel)
            // The paths from notes to their cards are drawn over this window's content.
            if let window = window.window { model.noteLink.install(in: window) }
        }
    }

    /// Opening the notes panel grows the window first, as Xcode does for its inspector. A window narrower than
    /// sidebar + viewer + panel (one saved while the panel was closed) otherwise sent AppKit into an endless
    /// constraint pass and the app aborted with an NSGenericException at launch.
    private func syncPanel(_ show: Bool) {
        guard show else {
            panelShown = false
            return
        }
        // Compact, the notes are the tray: the window doesn't grow for a side panel.
        guard !model.layout.isCompact else {
            panelShown = false
            return
        }
        guard !panelShown, let nsWindow = window.window else { return }
        NotesPanelRoom.make(in: nsWindow, panelWidth: 300) { fits in
            if fits {
                panelShown = model.showNotesPanel
            } else {
                // No room even at the screen's width: opening anyway would leave AppKit an impossible layout.
                model.showNotesPanel = false
                NSSound.beep()
            }
        }
    }
}

/// Widens a window so a panel of `panelWidth` fits beside what it already shows. AppKit's `minSize` lags behind
/// SwiftUI's real minimum (it read 622 pt where 720 were needed) and `fittingSize` reads 0, so neither can be
/// trusted to say exactly how much room there is: like Xcode with its inspector, the window grows by the whole
/// panel unless it clearly has the slack already. The resize runs on the next turn, outside SwiftUI's update, and
/// `done` says (once it has finished) whether the panel fits; false when the screen stopped the window short.
enum NotesPanelRoom {
    static func make(in window: NSWindow, panelWidth: CGFloat, done: @escaping @MainActor (Bool) -> Void) {
        let slack = window.frame.width - window.minSize.width
        guard slack < panelWidth + 100 else {
            DispatchQueue.main.async { done(true) }
            return
        }
        var frame = window.frame
        frame.size.width += panelWidth
        if let screen = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - frame.width))
        }
        let fits = slack + (frame.width - window.frame.width) >= panelWidth
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.isReduced ? 0 : 0.2
                window.animator().setFrame(frame, display: true)
            } completionHandler: {
                MainActor.assumeIsolated { done(fits) }
            }
        }
    }
}

/// The compact layout's explorer: slid over the document from the leading edge when asked (the sidebar button, ⌃⌘S),
/// and away again on Escape, a click beside it, or (as Settings says) once a file is opened from it. Built only while
/// shown, so nothing hidden takes the keyboard; its folders open again as they were (`FileNode.isExpanded`).
private struct CompactExplorer: View {
    @Environment(AppModel.self) private var model
    static let width: CGFloat = 300

    var body: some View {
        let shown = model.layout.isExplorerShown
        ZStack(alignment: .leading) {
            if shown {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { model.layout.isExplorerShown = false }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            if shown {
                ExplorerSidebar()
                    .frame(width: Self.width)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .overlay(alignment: .trailing) { Divider() }
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 4)
                    .onExitCommand { model.layout.isExplorerShown = false }
                    .transition(.move(edge: .leading).calmed)
            }
        }
        .animation(DS.Motion.smooth, value: shown)
    }
}

/// The window a view lives in, once it has one.
@Observable
final class WindowReference {
    @ObservationIgnored weak var window: NSWindow? {
        didSet { isAttached = window != nil }
    }
    var isAttached = false
}

private struct WindowReader: NSViewRepresentable {
    let reference: WindowReference

    func makeNSView(context: Context) -> NSView { WindowReaderView(reference: reference) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class WindowReaderView: NSView {
        let reference: WindowReference
        init(reference: WindowReference) {
            self.reference = reference
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [reference] in if reference.window !== window { reference.window = window } }
        }
    }
}

/// Sets `NSWindow.isDocumentEdited` for the window this view lives in.
private struct WindowEditedMarker: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let isEdited = isEdited
        // The view may not be in its window yet on the first update.
        DispatchQueue.main.async { view.window?.isDocumentEdited = isEdited }
    }
}

/// "Path copied", "Comment copied": a glass capsule that rises at the bottom of the window for a moment after a copy
/// that has no place of its own to say so (context menus, the tree). Never in the way: no hit testing.
struct CopyHUD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let flash = model.copyFlash {
                Label(flash.text, systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
                    .symbolRenderingMode(.multicolor)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.s)
                    .glassEffect(.regular, in: Capsule())
                    .transition((AnyTransition.move(edge: .bottom).combined(with: .opacity)).calmed)
                    .id(flash.id)
                    .task {
                        try? await Task.sleep(for: .milliseconds(1400))
                        model.clearCopyFlash(flash.id)
                    }
                    .accessibilityLabel(flash.text)
            }
        }
        .padding(.bottom, 40)
        .animation(DS.Motion.bouncy, value: model.copyFlash?.id)
        .allowsHitTesting(false)
    }
}

/// Back or Forward through the documents shown. A click takes one step; holding it (or its menu) lists the recent
/// places to jump to, as Safari's and Xcode's history buttons do.
private struct HistoryButton: View {
    enum Direction { case back, forward }
    @Environment(AppModel.self) private var model
    let direction: Direction

    /// Under an entry's name: the folder it is in, after its host's name; a page's host when it was reached through
    /// an ssh host, nothing more for one on the open web (its name already is its address).
    static func place(of entry: DocumentHistory.Entry, hosts: HostsModel) -> String {
        let host = hosts.entry(for: entry.hostID)?.name
        if DocumentKindDetector.isWebURL(entry.path) { return entry.hostID == .web ? "Web" : host.map { "via \($0)" } ?? "" }
        return host.map { "\($0) · " + PathUtilities.parent(of: entry.path) } ?? PathUtilities.parent(of: entry.path)
    }

    var body: some View {
        let entries = direction == .back ? model.history.recentBack() : model.history.recentForward()
        Menu {
            ForEach(entries, id: \.self) { entry in
                Button {
                    if direction == .back { model.goBack(to: entry) } else { model.goForward(to: entry) }
                } label: {
                    Text(Core.Document.displayName(of: entry.path))
                    Text(Self.place(of: entry, hosts: model.hosts))
                }
            }
        } label: {
            Label(direction == .back ? "Back" : "Forward", systemImage: direction == .back ? "chevron.backward" : "chevron.forward")
        } primaryAction: {
            if direction == .back { model.goBack() } else { model.goForward() }
        }
        .menuIndicator(.hidden)
        .disabled(entries.isEmpty)
        .help(direction == .back ? "Back (⌃⌘←)" : "Forward (⌃⌘→)")
    }
}
