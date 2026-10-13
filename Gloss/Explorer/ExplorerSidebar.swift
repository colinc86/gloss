import AppKit
import Core
import SwiftUI
import Viewers

/// The explorer column: a status row, the folder dropdown (which also picks the host), the tree, and the filter
/// bar with search, hidden files and Follow; the Web section in place of the tree when Web is the host.
struct ExplorerSidebar: View {
    @FocusState private var searchFocused: Bool
    @FocusState private var filterFocused: Bool
    @Environment(AppModel.self) private var model
    @State private var diagnostics: String?

    private var pickedHost: HostID { model.pickedHost }

    var body: some View {
        @Bindable var explorer = model.explorer
        VStack(spacing: 0) {
            if model.followHerdr, let pane = model.followedPane {
                FollowCard(pane: pane) { model.followHerdr = false }
                    .padding(.horizontal, DS.Space.s)
                    .padding(.top, DS.Space.s)
                    .transition((AnyTransition.move(edge: .top).combined(with: .opacity)).calmed)
            }
            if let status = statusRow {
                status
            }
            RootSwitcher(hostName: hostName, openFolder: openFolder)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.s)
            Divider()
            // A folder shows only under its own host: picking another with nothing open there says so instead.
            let shown = model.shownTab
            if pickedHost == .gloss {
                ReviewsSection()
            } else if pickedHost == .web {
                WebPagesSection()
            } else if explorer.contentSearch.isVisible, shown != nil {
                searchBar
                Divider()
                SearchResultsView()
            } else if shown != nil {
                FileOutlineView(model: explorer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(pickedHost == .github ? "No pull request open" : pickedHost == .atlassian ? "No issue or page open" : "No folder open", systemImage: pickedHost == .github ? "arrow.triangle.pull" : pickedHost == .atlassian ? "square.stack.3d.up" : "folder.badge.plus")
                } description: {
                    // On this Mac with nothing open the welcome screen beside it carries the button; one first step, not two.
                    Text(pickedHost == .local ? "Its files appear here." : pickedHost == .github ? "Its description, conversation and changed files appear here." : pickedHost == .atlassian ? "A project's issues or a space's pages appear here." : model.hosts.status(for: pickedHost) == .connected ? "Its files appear here." : "Connect to browse \(hostName(pickedHost))'s files.")
                } actions: {
                    if pickedHost == .github {
                        Button("Open Pull Request…") { model.presentOpenPullRequest() }
                    } else if pickedHost == .atlassian {
                        Button("Open Issue or Page…") { model.presentOpenAtlassian() }
                    } else if pickedHost == .local {
                        if !explorer.tabs.isEmpty { Button("Open Folder on this Mac…") { openFolder() } }
                    } else if model.hosts.status(for: pickedHost) == .connected {
                        Button("Open Folder on \(hostName(pickedHost))…") { openFolder() }
                    } else {
                        Button("Connect") { Task { await model.openRemoteRoot(hostID: pickedHost) } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(DS.Motion.smooth, value: model.followHerdr && model.followedPane != nil)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The Web section's own field narrows its pages; the file filter has nothing to filter there.
            if pickedHost != .web {
                VStack(spacing: 0) {
                    Divider()
                    footer
                }
                .background(.bar)
            }
        }
        .onChange(of: model.explorer.selectedTabID) { _, _ in
            Task { await model.folderBecameCurrent() }
        }
        .alert("Unknown host key", isPresented: Binding(get: { model.hosts.pendingHostKey != nil }, set: { _ in })) {
            Button("Accept and Connect") {
                if let pending = model.hosts.pendingHostKey {
                    let path = model.explorer.takePathAwaitingHostKey(pending.hostID)
                    Task { _ = await model.hosts.acceptNewHostKey(pending.hostID); await model.openRemoteRoot(hostID: pending.hostID, path: path) }
                }
            }
            Button("Cancel", role: .cancel) { model.explorer.pathAwaitingHostKey = nil }
        } message: {
            Text("This host's key is not in known_hosts yet.\n\(model.hosts.pendingHostKey?.fingerprint ?? "")\nAccept it for this host only?")
        }
    }

    // MARK: Hosts

    private func hostName(_ hostID: HostID) -> String {
        model.hostName(hostID)
    }

    private func openFolder() {
        model.presentOpenFolder(on: pickedHost)
    }

    /// The picked host's connection as a notice (connecting, waiting for the key agent, reconnecting, failed, or a
    /// warning while connected), and follow problems; nil when there is nothing to say.
    private var statusRow: AnyView? {
        var follow: String?
        if model.followHerdr, model.followedPane == nil { follow = model.followStatus }
        let status: HostsModel.Status? = pickedHost == .local || pickedHost.isVirtual ? nil : model.hosts.status(for: pickedHost)
        guard let content = ConnectionNoticeContent.make(
            host: hostName(pickedHost), status: status, progress: model.hosts.progress[pickedHost],
            warning: model.hosts.warnings[pickedHost], follow: follow
        ) else { return nil }
        return AnyView(
            ConnectionNotice(content: content) {
                if pickedHost != .local, content.showsDetails {
                    Button("Details") { Task { diagnostics = await model.hosts.diagnostics(for: pickedHost) } }
                        .popover(isPresented: Binding(get: { diagnostics != nil }, set: { if !$0 { diagnostics = nil } })) {
                            DiagnosticsPopover(text: diagnostics ?? "")
                        }
                }
                if content.offersConnect, pickedHost != .local {
                    Button(content.kind == .warning ? "Try Again" : "Connect") { Task { await model.openRemoteRoot(hostID: pickedHost) } }
                        .buttonStyle(.glassProminent)
                } else if content.isBusy, pickedHost != .local {
                    Button("Cancel") { Task { await model.hosts.disconnect(pickedHost) } }
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.top, DS.Space.s)
            .transition((AnyTransition.move(edge: .top).combined(with: .opacity)).calmed)
        )
    }


    // MARK: Roots, search, footer

    private var searchBar: some View {
        @Bindable var search = model.explorer.contentSearch
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search file contents", text: $search.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    model.runContentSearch()
                }
                // Find in Files puts the caret here, as ⌘⇧F does in other editors; Escape puts the tree back.
                .onAppear { searchFocused = true }
                .onChange(of: search.focusRequest) { _, _ in searchFocused = true }
                .onKeyPress(.escape) {
                    search.isVisible = false
                    search.cancel()
                    return .handled
                }
            if search.isSearching { ProgressView().controlSize(.small) }
            // A borderless toggle draws no "on" state, so regex mode was invisible; this one fills when on.
            Button {
                search.isRegex.toggle()
                if !search.query.isEmpty { model.runContentSearch() }
            } label: {
                Text(".*")
                    .font(.caption.monospaced().weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(search.isRegex ? Color.white : Color.secondary)
                    .background(search.isRegex ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Regular expression")
            .accessibilityValue(search.isRegex ? "on" : "off")
            .help(search.isRegex ? "Regular expression (click for plain text)" : "Plain text (click for a regular expression); case is ignored unless the query has a capital letter")
            Button {
                search.isVisible = false
                search.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .font(.callout)
    }

    private var footer: some View {
        @Bindable var explorer = model.explorer
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            TextField("Filter files", text: $explorer.filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onChange(of: explorer.filterFocusRequest) { _, _ in filterFocused = true }
                .onKeyPress(.escape) {
                    if explorer.filter.isEmpty { filterFocused = false } else { explorer.filter = "" }
                    return .handled
                }
            Button {
                explorer.contentSearch.isVisible.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            // A pull request, project or space is browsed, not searched.
            .disabled(model.shownTab?.hostID.isVirtual == true)
            .onChange(of: model.shownTab?.hostID.isVirtual == true) { _, virtual in if virtual { explorer.contentSearch.isVisible = false } }
            .help("Search file contents (⌘⇧F)")
            // Shows its state, not just its function: struck through while hidden files stay hidden.
            Toggle(isOn: $explorer.showDotfiles) {
                Image(systemName: explorer.showDotfiles ? "eye" : "eye.slash")
                    .foregroundStyle(explorer.showDotfiles ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(explorer.showDotfiles ? "Hide hidden files (⌘⇧.)" : "Show hidden files (⌘⇧.)")
            .accessibilityLabel("Show hidden files")
            // Only where Herdr exists: following needs its focus events. Kept while following, so it can be stopped.
            if !model.herdrHosts.isEmpty || model.followHerdr {
                FollowToggle(isOn: Binding(get: { model.followHerdr }, set: { model.followHerdr = $0 }))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .font(.callout)
    }
}

/// ssh's own account of a connection, copyable, so a stuck connect can be reported precisely.
private struct DiagnosticsPopover: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 520, height: 260)
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
        .padding(12)
    }
}

/// Asks for a directory on a remote host; there is no open panel for SFTP.
struct RemotePathPrompt: Identifiable {
    var hostID: HostID
    var hostName: String
    var initialPath: String
    var id: String { hostID.rawValue }
}

struct RemotePathSheet: View {
    let prompt: RemotePathPrompt
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a folder on \(prompt.hostName)").font(.headline)
            TextField("Absolute path", text: $path)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Text("Any directory you can read over SFTP. The home directory is opened when you pick the host.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: submit).keyboardShortcut(.defaultAction).disabled(!path.hasPrefix("/"))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { path = prompt.initialPath }
    }

    private func submit() {
        guard path.hasPrefix("/") else { return }
        open(path)
        dismiss()
    }
}

/// What follow mode is tracking right now: the agent's live state, its name and host, the pane, and its folder.
private struct FollowCard: View {
    let pane: AppModel.FollowedPane
    let stop: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "scope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Space.xs) {
                    Text("Following").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    StatusDot(status: pane.status)
                }
                HStack(spacing: DS.Space.xs) {
                    if let host = pane.host {
                        Text(host).font(.caption.weight(.semibold)).foregroundStyle(.teal)
                    }
                    Text(pane.agent).font(.callout.weight(.semibold))
                    Text(pane.paneID).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                if let path = pane.path {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(path)
                }
            }
            Spacer(minLength: DS.Space.xs)
            InlineIconButton(title: "Stop following", symbol: "xmark", emphasized: true, action: stop)
        }
        .padding(DS.Space.s)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.m + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m + 2, style: .continuous).strokeBorder(Color.accentColor.opacity(0.2)))
        .animation(DS.Motion.smooth, value: pane)
    }
}

/// A remote host's connection, said plainly: what is happening, what it means, and the one action that helps.
/// Busy stages show a spinner, a key agent waiting for approval is a mode with a pulsing key, failures are warnings.
struct ConnectionNoticeContent: Equatable {
        var kind: NoticeKind
        var symbol: String
        var title: String
        var detail: String
        var isBusy = false
        var showsDetails = false
    var offersConnect = false

    typealias Content = ConnectionNoticeContent

    static func make(host: String, status: HostsModel.Status?, progress: String?, warning: String?, follow: String?) -> Content? {
        var result: Content?
        switch status {
        case nil:
            break
        case .idle?:
            result = Content(kind: .info, symbol: "network.slash", title: "Not connected", detail: "Connect to browse \(host)'s files.", offersConnect: true)
        case .connecting?:
            result = Content(kind: .info, symbol: "network", title: "Connecting to \(host)", detail: progress ?? "Starting ssh…", isBusy: true, showsDetails: true)
        case .waitingForAgent?:
            result = Content(kind: .mode, symbol: "key.fill", title: "Waiting for your key agent",
                             detail: "Approve the request to sign in to \(host). Its prompt may be behind other windows.", isBusy: true, showsDetails: true)
        case .reconnecting(let attempt)?:
            result = Content(kind: .info, symbol: "arrow.triangle.2.circlepath", title: "Reconnecting to \(host)", detail: "Attempt \(attempt)…", isBusy: true, showsDetails: true)
        case .failed(let message)?:
            result = Content(kind: .warning, symbol: "exclamationmark.triangle.fill", title: "Couldn't connect to \(host)", detail: message, showsDetails: true, offersConnect: true)
        case .connected?:
            if let warning { result = Content(kind: .warning, symbol: "exclamationmark.circle", title: "Connected with a problem", detail: warning) }
        }
        if let follow {
            if var existing = result {
                existing.detail += " · " + follow
                result = existing
            } else {
                result = Content(kind: .info, symbol: "scope", title: "Follow Herdr", detail: follow)
            }
        }
        return result
    }
}

struct ConnectionNotice<Actions: View>: View {
    let content: ConnectionNoticeContent
    @ViewBuilder var actions: Actions

    var body: some View {
        Notice(kind: content.kind, symbol: content.symbol, title: content.title, detail: content.detail, pulses: content.kind == .mode) {
            if content.isBusy { ProgressView().controlSize(.small) }
            actions
        }
    }
}
