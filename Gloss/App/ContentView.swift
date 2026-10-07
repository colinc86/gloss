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
    @Environment(\.openWindow) private var openWindow

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
        NavigationSplitView {
            ExplorerSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 600)
        } detail: {
            Group {
                if let session = model.activeSession {
                    ViewerPane(session: session)
                        .id(session.id)
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
            .toolbar(removing: .title)
            // A page's title, once it has loaded, names it in the explorer's Web section and in Open Quickly.
            .onChange(of: model.activeSession?.html?.pageTitle) { _, title in
                guard let title, let session = model.activeSession, DocumentKindDetector.isWebURL(session.path) else { return }
                model.webPages.setTitle(title, url: session.path, hostID: session.hostID)
            }
            .inspector(isPresented: Binding(get: { panelShown }, set: { model.showNotesPanel = $0 })) {
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
                // Only where Herdr exists: following needs its focus events. Kept while following, so it can be stopped.
                if !model.herdrHosts.isEmpty || model.followHerdr {
                    ToolbarItem(placement: .navigation) {
                        FollowToggle(isOn: Binding(get: { model.followHerdr }, set: { model.followHerdr = $0 }))
                    }
                    // Lit, it draws its own accent disc; the glass would wash it out.
                    .sharedBackgroundVisibility(model.followHerdr ? .hidden : .automatic)
                }
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
        .sheet(isPresented: Binding(get: { model.pullRequestPicker.isPresented }, set: { if !$0 { model.pullRequestPicker.dismiss() } })) {
            OpenPullRequestSheet()
        }
        .sheet(isPresented: Binding(get: { model.atlassianPicker.isPresented }, set: { if !$0 { model.atlassianPicker.dismiss() } })) {
            OpenAtlassianSheet()
        }
        .sheet(isPresented: Binding(get: { model.quickOpen.isPresented }, set: { if !$0 { model.quickOpen.dismiss() } })) {
            QuickOpenSheet()
        }
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
            Text(pending.hostName.map { "A link asked to connect to \($0) and open \(pending.path)." } ?? "A link asked to open \(pending.path).")
                + Text(" Open it only if you followed this link yourself.")
        }
        .dropToOpen()
        .overlay(alignment: .bottom) { CopyHUD() }
        // With the notes panel closed the update toast (#10) has the window's corner; open, it sits with the panel's.
        .overlay(alignment: .bottomTrailing) {
            if !panelShown {
                AgentsUpdateToast()
                    .frame(maxWidth: 380)
                    .padding(DS.Space.m)
            }
        }
        // The dot in the close button whenever any open document has unsaved edits, not only the visible one.
        .background(WindowEditedMarker(isEdited: !model.unsavedSessions.isEmpty))
        .background(WindowReader(reference: window))
        .onChange(of: model.showNotesPanel, initial: true) { _, show in
            syncPanel(show)
            model.noteLink.isPanelShown = show
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
private struct CopyHUD: View {
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
