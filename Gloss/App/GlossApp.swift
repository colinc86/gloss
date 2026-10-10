import AppKit
import Core
import OSLog
import Remote
import SwiftUI
import Viewers

@main
struct GlossApp: App {
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        let options = AppLaunchOptions(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
        Log.app.info("Launch options: \(String(describing: options), privacy: .public)")
        let model = AppModel(launchOptions: options)
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .task { await model.start() }
                .onOpenURL { url in Task { await URLRouter.handle(url, model: model) } }
                // The open window takes gloss:// URLs; without this SwiftUI opens a new window per URL.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1200, height: 800)
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsWindow()
        }
        .windowResizability(.contentSize)
    }
}

/// Menus and shortcuts. Grows with each step; see the plan's shortcut table.
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            // There is no help book; the shortcuts window is the reference the app does have.
            Button { openWindow(id: "shortcuts") } label: { Label("Keyboard Shortcuts", systemImage: "keyboard") }
                .keyboardShortcut("/", modifiers: [.command])
            Divider()
            if model.updates.isAvailable {
                Button { model.updates.checkForUpdates() } label: { Label("Check for Updates…", systemImage: "arrow.down.circle") }
                    .disabled(!model.updates.canCheckForUpdates)
            }
            Button { model.presentReport() } label: { Label("Report a Bug or Request a Feature…", systemImage: "ladybug") }
        }
        CommandGroup(replacing: .appInfo) {
            Button("About Gloss") { AboutPanel.show() }
            if model.updates.isAvailable {
                Button("Check for Updates…") { model.updates.checkForUpdates() }
                    .disabled(!model.updates.canCheckForUpdates)
            }
        }
        CommandGroup(after: .newItem) {
            Button {
                model.explorer.chooseRootWithPanel(hostID: .local)
            } label: { Label("Open Folder…", systemImage: "folder") }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Button { model.presentQuickOpen() } label: { Label("Open Quickly…", systemImage: "doc.text.magnifyingglass") }
                .keyboardShortcut("p", modifiers: [.command])
            // The window title turns into the address field.
            Button { model.presentOpenLocation() } label: { Label("Open Location…", systemImage: "globe") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button { model.presentOpenPullRequest() } label: { Label("Open Pull Request…", systemImage: "arrow.triangle.pull") }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button { model.presentOpenAtlassian() } label: { Label("Open Jira Issue or Confluence Page…", systemImage: "ticket") }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .saveItem) {
            // Replacing the save group also took Close with it; ⌘W closes whichever window is in front.
            Button { NSApp.keyWindow?.performClose(nil) } label: { Label("Close Window", systemImage: "xmark") }
                .keyboardShortcut("w", modifiers: [.command])
            Divider()
            Button {
                guard let session = model.activeSession else { return }
                Task { await session.save() }
            } label: { Label("Save", systemImage: "square.and.arrow.down") }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(model.activeSession?.textController == nil)
            Button {
                Task {
                    // A document that could not be saved (a write error, or a conflict) is brought forward.
                    if let first = await model.saveAll().first { model.openDocument(hostID: first.hostID, path: first.path) }
                }
            } label: { Label("Save All", systemImage: "square.and.arrow.down.on.square") }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(model.unsavedSessions.isEmpty)
        }
        CommandMenu("Notes") {
            // ⌘↩ belongs to whatever the window offers: the Add Note button while a selection shows it, Send otherwise.
            Button { model.beginNoteInMainWindow() } label: { Label("New Note from Selection", systemImage: "note.text.badge.plus") }
                .keyboardShortcut(model.selectionAwaitsNote ? KeyboardShortcut(.return, modifiers: .command) : KeyboardShortcut("n", modifiers: [.command, .shift]))
                .disabled(model.activeSession == nil || model.isShowingPastIteration)
            // The rendered page's pick mode, for any element; pictures need no mode.
            let page = model.activeSession?.html
            Toggle(isOn: Binding(get: { page?.isNoteMode ?? false }, set: { page?.isNoteMode = $0 })) {
                Label("Pick Element on Page", systemImage: "rectangle.dashed")
            }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(page?.mode != .rendered)
            Button { Task { await model.sendVisibleDrafts() } } label: {
                Label("Send Shown Notes — \(model.sendScope.rawValue)", systemImage: "paperplane")
            }
                .keyboardShortcut(model.selectionAwaitsNote ? nil : KeyboardShortcut(.return, modifiers: .command))
                .disabled(!model.send.isTargetAvailable || model.visibleDrafts.isEmpty)
            Button { Task { await model.sendAllDrafts(scope: .all) } } label: { Label("Send Shown Drafts in This Location (\(model.sendSelection(scope: .all).notes.count))", systemImage: "paperplane.fill") }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!model.send.isTargetAvailable)
            Button { Task { await model.copyVisibleDrafts() } } label: { Label("Copy Shown Notes as Packet", systemImage: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.visibleDrafts.isEmpty)
            Divider()
            // The selection may be several notes (issue #8): each command takes the ones it applies to.
            let selected = model.notesPanel.selectedNotes
            let sendable = NotesPanelModel.sendable(selected), resolvable = NotesPanelModel.resolvable(selected)
            let plural = selected.count > 1
            Button {
                Task { await model.send(noteIDs: sendable.map(\.id)) }
            } label: { Label(plural ? "Send Selected Notes" : "Send Selected Note", systemImage: "paperplane") }
            .disabled(sendable.isEmpty || !model.send.isTargetAvailable)
            Button {
                Task { await model.copyPacket(noteIDs: selected.map(\.id)) }
            } label: { Label(plural ? "Copy Selected Notes as Packet" : "Copy Selected Note as Packet", systemImage: "doc.on.clipboard") }
            .disabled(selected.isEmpty)
            Button {
                Task { await model.notesPanel.resolve(resolvable.map(\.id)) }
            } label: { Label(plural ? "Resolve Selected Notes" : "Resolve Selected Note", systemImage: "checkmark.circle") }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(resolvable.isEmpty)
            Divider()
            // A new round of notes on the document in front (issue #18); open notes are asked about, as Settings says.
            Button { model.newIteration() } label: { Label("New Iteration", systemImage: "square.stack.3d.up") }
                .disabled(model.activeSession?.document == nil || model.activeSession?.kind == .web || model.isShowingPastIteration)
            Divider()
            // ⌘' and ⇧⌘', as Xcode steps through issues.
            Button { model.stepNote(forward: true) } label: { Label("Next Note", systemImage: "chevron.down") }
                .keyboardShortcut("'", modifiers: [.command])
                .disabled(model.shownSession?.steppableNotes.isEmpty ?? true)
            Button { model.stepNote(forward: false) } label: { Label("Previous Note", systemImage: "chevron.up") }
                .keyboardShortcut("'", modifiers: [.command, .shift])
                .disabled(model.shownSession?.steppableNotes.isEmpty ?? true)
            // ⌥⌘↓ and ⌥⌘↑: the hunks of a pull request's file.
            Button { model.stepChange(forward: true) } label: { Label("Next Change", systemImage: "chevron.down.2") }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model.activeSession?.changeHunks.isEmpty ?? true)
            Button { model.stepChange(forward: false) } label: { Label("Previous Change", systemImage: "chevron.up.2") }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(model.activeSession?.changeHunks.isEmpty ?? true)
            Divider()
            Toggle(isOn: Binding(get: { model.showNotesPanel }, set: { model.showNotesPanel = $0 })) { Label("Show Notes Panel", systemImage: "sidebar.trailing") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Toggle(isOn: Binding(get: { model.noteLink.isLinked }, set: { model.setNotesLinked($0) })) { Label("Follow Page in Notes Panel", systemImage: "link") }
            Toggle(isOn: Binding(get: { model.noteLink.showsPaths }, set: { model.noteLink.showsPaths = $0 })) {
                Label("Show Paths to Notes", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
            }
            .disabled(!model.noteLink.isLinked)
            Button {
                model.notesPanel.searchFocusPending = true
                model.showNotesPanel = true
                model.notesPanel.searchFocusRequest += 1
            } label: { Label("Search Notes", systemImage: "magnifyingglass") }
            // No shortcut: ⌥⌘F is Find and Replace in most Mac apps, and the menu item is enough.
        }
        CommandMenu("Go") {
            // ⌃⌘← and ⌃⌘→, as Xcode goes back and forward; ⌘[ and ⌘] stay with the review browser's own history.
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(!model.history.canGoBack)
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(!model.history.canGoForward)
            Divider()
            // The same field as File › Open Location… (⇧⌘L), where a browser keeps it.
            Button { model.presentOpenLocation() } label: { Label("Go to Address…", systemImage: "character.cursor.ibeam") }
            Divider()
            // The sidebar's crosshair, reachable with the sidebar closed. Only where Herdr exists, unless following.
            Toggle(isOn: Binding(get: { model.followHerdr }, set: { model.followHerdr = $0 })) { Label("Follow Herdr", systemImage: "scope") }
                .disabled(model.herdrHosts.isEmpty && !model.followHerdr)
        }
        CommandGroup(after: .toolbar) {
            Toggle(isOn: Binding(
                get: { model.explorer.showDotfiles },
                set: { model.explorer.showDotfiles = $0 }
            )) { Label("Show Hidden Files", systemImage: "eye") }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle(isOn: Binding(get: { model.notesPanel.showResolved }, set: { model.notesPanel.showResolved = $0 })) {
                Label("Show Resolved Notes", systemImage: "checkmark.circle")
            }
            Toggle(isOn: Binding(get: { model.notesPanel.separateResolved }, set: { model.notesPanel.separateResolved = $0 })) {
                Label("Separate Resolved Notes", systemImage: "line.3.horizontal.decrease")
            }
            .disabled(!model.notesPanel.showResolved)
            Button { model.explorer.refreshAll() } label: { Label("Refresh Explorer", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: [.command])
            Button {
                // The filter narrows the tree, so the tree must be what's showing.
                if model.explorer.contentSearch.isVisible {
                    model.explorer.contentSearch.isVisible = false
                    model.explorer.contentSearch.cancel()
                }
                model.explorer.filterFocusRequest += 1
            } label: { Label("Filter Files", systemImage: "line.3.horizontal.decrease.circle") }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(model.shownTab == nil)
            Button {
                model.explorer.contentSearch.isVisible = true
                model.explorer.contentSearch.focusRequest += 1
            } label: { Label("Find in Files", systemImage: "text.magnifyingglass") }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.shownTab == nil || model.selectedRootIsVirtual)
            Button { model.revealActiveDocumentInExplorer() } label: { Label("Reveal in Explorer", systemImage: "scope") }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(model.activeSession == nil)
            Button { model.shownSession?.isGoToLinePresented = true } label: { Label("Go to Line…", systemImage: "arrow.right.to.line") }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(model.shownSession?.textController == nil)
            Button { model.activeSession?.toggleMarkdownMode() } label: { Label("Toggle Rendered / Source", systemImage: "chevron.left.forwardslash.chevron.right") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.activeSession?.rendered == nil)
        }
    }
}

/// Closes sessions and the database when the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    private var signalSources: [any DispatchSourceSignal] = []
    private var terminationRequested = false
    /// A quit is waiting (`.terminateLater`) for saves or the shutdown to finish.
    private var quitInProgress = false

    /// SIGTERM (`kill`, `pkill`, a logout that times out), SIGINT, and SIGHUP would end the process without
    /// `applicationShouldTerminate`, orphaning every SSH master to launchd. They become a normal quit instead;
    /// a second signal while that quit is still waiting kills the masters and exits at once.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One window with its own folder switcher; macOS's window tabs only added "Show Tab Bar" to the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        switch Self.model?.launchOptions.appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.handleTerminationSignal() }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func handleTerminationSignal() {
        if quitInProgress, !terminationRequested {
            // A quit is already saving and shutting down: let it finish rather than start a second one under it.
            terminationRequested = true
            return
        }
        if terminationRequested {
            AppDelegate.model?.hosts.killMasters()
            exit(0)
        }
        terminationRequested = true
        // Not from inside this main-queue callout: `terminate` answered with `.terminateLater` spins a nested
        // event loop until the shutdown Task replies, and that Task needs the main queue this block is holding.
        // A run-loop perform runs outside the queue, so the shutdown can proceed (and a second signal can land).
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    /// Quitting waits for the SSH masters to exit (bounded) so no `ssh` process outlives the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppDelegate.model, !model.isShutDown else { return .terminateNow }
        guard !quitInProgress else { return .terminateCancel }   // the pending quit answers for itself
        let unsaved = model.unsavedSessions
        if !unsaved.isEmpty, !terminationRequested {
            // Quitting used to drop unsaved edits without a word.
            switch Self.askAboutUnsaved(unsaved) {
            case .alertFirstButtonReturn:
                quitInProgress = true
                Task { @MainActor in
                    let failed = await model.saveAll()
                    if let first = failed.first {
                        // A failed write or a conflict: stay open and show it.
                        model.openDocument(hostID: first.hostID, path: first.path)
                        self.quitInProgress = false
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    await model.shutDown()
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            case .alertSecondButtonReturn:
                return .terminateCancel
            default:
                break   // Don't Save
            }
        }
        quitInProgress = true
        let signalled = terminationRequested
        Task { @MainActor in
            // A termination signal leaves nobody to answer a prompt: save what can be saved, then give writes
            // already under way a moment to land before the connections they use are closed.
            if signalled, !unsaved.isEmpty { _ = await withDeadline(.seconds(4)) { await model.saveAll() } }
            // A save the reader started (⌘S, then ⌘Q) finishes before its connection closes: on a slow host 2 s cut
            // it off and the save was lost. A signal leaves little time, so it still waits only briefly.
            let deadline = ContinuousClock.now + (signalled ? .seconds(2) : .seconds(30))
            while model.isSavingAnything, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            await model.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func askAboutUnsaved(_ sessions: [DocumentSession]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = sessions.count == 1
            ? "Save changes to \(sessions[0].fileName) before quitting?"
            : "Save changes to \(sessions.count) documents before quitting?"
        let names = sessions.prefix(8).map(\.fileName).joined(separator: "\n")
        alert.informativeText = (sessions.count > 1 ? names + (sessions.count > 8 ? "\n…" : "") + "\n\n" : "") + "Your changes are lost if you don't save them."
        alert.addButton(withTitle: sessions.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save").hasDestructiveAction = true
        return alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.model?.shutDownSynchronously()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Right-click on the Dock icon: questions waiting from agents, then recent folders, so the common next step is
    /// one click from wherever you are.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model = AppDelegate.model else { return nil }
        let menu = NSMenu()
        let questions = model.notesPanel.groups.reduce(0) { $0 + $1.notes.filter(\.waitingOnUser).count }
        if questions > 0 {
            let item = NSMenuItem(title: questions == 1 ? "1 Question from an Agent…" : "\(questions) Questions from Agents…",
                                  action: #selector(showQuestions), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let recents = (model.explorer.recentsByHost[.local] ?? model.explorer.recentRoots.filter { $0.hostID == .local }).prefix(5)
        for root in recents {
            let item = NSMenuItem(title: (root.path as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = root.path
            item.toolTip = root.path
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// Brings the main window forward, reopening it if it was closed (the app outlives its last window).
    private func showMainWindow(_ model: AppModel) {
        NSApp.activate()
        if let window = model.mainWindow { window.makeKeyAndOrderFront(nil) } else { model.openMainWindow() }
    }

    @objc private func showQuestions() {
        guard let model = AppDelegate.model else { return }
        showMainWindow(model)
        // The questions the menu counted, not whatever colour or search was left on.
        model.notesPanel.clearFilters()
        model.notesPanel.filter = .attention
        model.showNotesPanel = true
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let model = AppDelegate.model, let path = sender.representedObject as? String else { return }
        showMainWindow(model)
        Task { await model.explorer.openRoot(hostID: .local, path: path) }
    }
}

/// The standard About panel, with a line on what the app is for and what it is built on.
enum AboutPanel {
    static func show() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: center,
        ]
        let quiet: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center,
        ]
        let credits = NSMutableAttributedString(string: "Mark up any file and hand the notes to Claude Code, Codex, or OpenCode.\n", attributes: body)
        credits.append(NSAttributedString(string: "Built with Tree-sitter, swift-markdown, GRDB, and the MCP Swift SDK.", attributes: quiet))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
