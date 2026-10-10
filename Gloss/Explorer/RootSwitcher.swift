import Core
import Integrations
import SwiftUI
import Viewers

/// The folder above the tree, and the way to every other: one row naming the open root (or the host, when none is
/// open or Web is picked), which opens a switcher of hosts, then open folders, favorites (pinned, on every host),
/// and recent ones on the picked host. Replaces a strip of chips that scrolled out of sight once a few folders were open, and
/// gives folders you come back to a place that survives closing them.
struct RootSwitcher: View {
    @Environment(AppModel.self) private var model
    let hostName: (HostID) -> String
    let openFolder: () -> Void
    @State private var isOpen = false
    @State private var hovering = false

    /// The folder in front, when it is on the picked host; a folder never shows under another host's name.
    private var shownTab: RootTab? { model.shownTab }

    var body: some View {
        let explorer = model.explorer
        let picked = model.pickedHost
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: DS.Space.s) {
                if shownTab == nil {
                    // No folder to name: the host is what the row is about.
                    let status = model.hosts.status(for: picked)
                    Image(systemName: HostMenu.symbol(picked, status: status))
                        .foregroundStyle(SwitcherHostRow.failed(status) ? Color.orange : Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                    Text(HostMenu.label(picked, name: hostName(picked)))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(model.hosts.entry(for: picked)?.kind == .ssh ? Color.teal : Color.primary)
                        .lineLimit(1)
                    if picked != .web {
                        Text(HostMenu.nothingOpen(picked))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if let tab = shownTab {
                    Image(systemName: SwitcherEntry.symbol(hostID: tab.hostID, path: tab.path, open: true))
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                    if tab.hostID != .local, !tab.hostID.isVirtual {
                        Text(hostName(tab.hostID))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.teal)
                    }
                    Text(tab.hostID == .github ? (PullRequestPath(tab.path).map { "\($0.repository) #\($0.number)" } ?? tab.title)
                         : tab.hostID == .atlassian ? (SwitcherEntry.atlassianLabel(tab.path) ?? tab.title) : tab.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                    CountBadge(count: explorer.folderCountForRoot(tab))
                }
                Spacer(minLength: DS.Space.xs)
                if explorer.tabs.count > 1 {
                    Text("\(explorer.tabs.count) open")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(explorer.tabs.count)))
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(Color.primary.opacity(hovering || isOpen ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .animation(DS.Motion.smooth, value: isOpen)
        .animation(DS.Motion.smooth, value: explorer.selectedTabID)
        .help(shownTab.map { "\(hostName($0.hostID)): \($0.path). Click to switch folders or hosts." } ?? "Switch folders or hosts")
        .accessibilityLabel(shownTab.map { "Folder \($0.title)" }
                            ?? (picked == .web ? "Web" : "\(HostMenu.label(picked, name: hostName(picked))), \(HostMenu.nothingOpen(picked).lowercased())"))
        .accessibilityHint("Shows hosts, and open, favorite, and recent folders")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            RootSwitcherList(hostName: hostName, openFolder: { isOpen = false; openFolder() }, dismiss: { isOpen = false })
                .environment(model)
        }
        .task(id: isOpen) {
            if isOpen { await explorer.refreshRecents(hostIDs: Set(explorer.tabs.map(\.hostID) + [model.pickedHost])) }
        }
        // A host picked in the list shows its recent folders there.
        .task(id: model.pickedHost) {
            if isOpen { await explorer.refreshRecents(hostIDs: [model.pickedHost]) }
        }
    }
}

private struct CountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.xs + 1)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .contentTransition(.numericText(value: Double(count)))
                .help("\(count) open note\(count == 1 ? "" : "s") in this folder")
        }
    }
}

/// One folder in the switcher: open (a tab) or closed (a favorite or recent root). A favorite that is open is
/// listed once, under Favorites, with its tab's id.
nonisolated struct SwitcherEntry: Identifiable, Equatable {
    enum Section: String { case open = "Open", favorites = "Favorites", recent = "Recent" }
    let id: RootID
    let hostID: HostID
    let path: String
    let pinned: Bool
    let section: Section
    let isOpen: Bool
    var title: String {
        if hostID == .github, let pull = PullRequestPath(path) { return "\(pull.repository) #\(pull.number)" }
        if hostID == .atlassian, let label = Self.atlassianLabel(path) { return label }
        return (path as NSString).lastPathComponent
    }

    /// One symbol per kind of root, the same in the switcher, the tree and the pickers.
    nonisolated static func symbol(hostID: HostID, path: String, open: Bool) -> String {
        switch hostID {
        case .local: open ? "folder.fill" : "folder"
        case .github: "arrow.triangle.pull"
        case .atlassian: path.hasPrefix("/jira") ? "ticket" : "doc.text"
        default: "network"
        }
    }

    /// What sits under a root's name: where a folder is, or what kind of thing an integration root is.
    nonisolated static func subtitle(hostID: HostID, path: String) -> String {
        switch hostID {
        case .github: "Pull request"
        case .atlassian: path.hasPrefix("/jira") ? "Jira project" : "Confluence space"
        // `~` is this Mac's home; a host's folders are shown as they are.
        case .local: PathUtilities.abbreviatingHome(PathUtilities.parent(of: path), home: NSHomeDirectory())
        default: PathUtilities.parent(of: path)
        }
    }

    /// `Jira · CP` or `Confluence · ENG` for an Atlassian root.
    nonisolated static func atlassianLabel(_ path: String) -> String? {
        switch AtlassianPath(path) {
        case .jiraProject(let project)?: "Jira · \(project)"
        case .confluenceSpace(let space)?: "Confluence · \(space)"
        case .confluencePageFolder(let space, _, _)?: "Confluence · \(space) page"
        default: nil
        }
    }

    /// The sections in order, filtered by `query` (name first, then anywhere in the path; case-insensitive).
    /// Favorites (from every host) always list every favorite, by name, open ones marked; Open lists the open
    /// folders that aren't favorites; Recent (the picked host's) leaves out both, at most `recentLimit` of them
    /// without a query. Folders are matched by `ExplorerModel.markKey`, so two spellings of one are one folder.
    static func sections(tabs: [(id: RootID, hostID: HostID, path: String)], favorites: [Root], recents: [Root], query: String,
                         recentLimit: Int = 6) -> [(section: Section, entries: [SwitcherEntry])] {
        func key(_ hostID: HostID, _ path: String) -> String { ExplorerModel.markKey(hostID, path) }
        var tabsByKey: [String: (id: RootID, hostID: HostID, path: String)] = [:]
        for tab in tabs where tabsByKey[key(tab.hostID, tab.path)] == nil { tabsByKey[key(tab.hostID, tab.path)] = tab }
        let favoriteKeys = Set(favorites.map { key($0.hostID, $0.path) })
        let pinned = favorites.map { root in
            let tab = tabsByKey[key(root.hostID, root.path)]
            return SwitcherEntry(id: tab?.id ?? root.id, hostID: root.hostID, path: tab?.path ?? root.path, pinned: true, section: .favorites, isOpen: tab != nil)
        }
        .sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            guard order == .orderedSame else { return order == .orderedAscending }
            return ($0.hostID.rawValue, $0.path) < ($1.hostID.rawValue, $1.path)
        }
        let open = tabs.filter { !favoriteKeys.contains(key($0.hostID, $0.path)) }
            .map { SwitcherEntry(id: $0.id, hostID: $0.hostID, path: $0.path, pinned: false, section: .open, isOpen: true) }
        let others = recents.filter { !favoriteKeys.contains(key($0.hostID, $0.path)) && tabsByKey[key($0.hostID, $0.path)] == nil }
            .map { SwitcherEntry(id: $0.id, hostID: $0.hostID, path: $0.path, pinned: false, section: .recent, isOpen: false) }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        func filtered(_ entries: [SwitcherEntry]) -> [SwitcherEntry] {
            guard !needle.isEmpty else { return entries }
            let byName = entries.filter { $0.title.lowercased().contains(needle) }
            let byPath = entries.filter { !$0.title.lowercased().contains(needle) && $0.path.lowercased().contains(needle) }
            return byName + byPath
        }
        let recent = filtered(others)
        return [(.open, filtered(open)), (.favorites, filtered(pinned)), (.recent, needle.isEmpty ? Array(recent.prefix(recentLimit)) : recent)]
            .filter { !$0.entries.isEmpty }
    }
}

/// A row of the switcher: a host, then the folders.
nonisolated enum SwitcherItem: Equatable {
    case host(HostID)
    case folder(SwitcherEntry)

    /// Where the highlight starts: with a filter, on the first folder it left (so `git` and Return opens a folder,
    /// not GitHub), or the first host when none; without one, on the folder in front (`selectedTabID`, nil when
    /// it is not on the picked host), so ↓ and Return go to the next, or else on the picked host.
    static func start(in items: [SwitcherItem], query: String, selectedTabID: RootID?, pickedHost: HostID) -> Int {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return items.firstIndex { if case .folder = $0 { true } else { false } } ?? 0
        }
        if let selectedTabID, let index = items.firstIndex(where: { if case .folder(let entry) = $0 { entry.id == selectedTabID } else { false } }) {
            return index
        }
        return items.firstIndex(of: .host(pickedHost)) ?? 0
    }
}

/// The switcher's sections, keyboard first: a filter field takes typing, ↑ and ↓ move the highlight through the
/// hosts and the folders, Return picks it. Each folder row can be starred, and open ones closed.
private struct RootSwitcherList: View {
    @Environment(AppModel.self) private var model
    let hostName: (HostID) -> String
    let openFolder: () -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var fieldFocused: Bool

    /// The hosts matching the filter, the folder sections, and every row in order for the highlight.
    private func lists() -> (hosts: [HostsModel.Entry], sections: [(section: SwitcherEntry.Section, entries: [SwitcherEntry])], flat: [SwitcherItem]) {
        let explorer = model.explorer
        // A favorite on a host no longer listed (an ssh config alias turned off) has nowhere to open.
        let favorites = explorer.favorites.filter { $0.hostID == .local || $0.hostID.isVirtual || model.hosts.entry(for: $0.hostID) != nil }
        let sections = SwitcherEntry.sections(tabs: explorer.tabs.map { (id: $0.id, hostID: $0.hostID, path: $0.path) }, favorites: favorites,
                                              recents: explorer.recentsByHost[model.pickedHost] ?? [], query: query)
        let hosts = HostMenu.matching(model.hosts.entries, query: query)
        return (hosts, sections, hosts.map { SwitcherItem.host($0.id) } + sections.flatMap(\.entries).map(SwitcherItem.folder))
    }

    var body: some View {
        let explorer = model.explorer
        let (hosts, sections, flat) = lists()
        let current = flat.indices.contains(highlight) ? flat[highlight] : nil
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter hosts and folders", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onKeyPress(.downArrow) { move(1, count: flat.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: flat.count); return .handled }
                    .onSubmit {
                        guard flat.indices.contains(highlight) else { return }
                        switch flat[highlight] {
                        case .host(let id): if let entry = hosts.first(where: { $0.id == id }) { choose(entry) }
                        case .folder(let entry): choose(entry)
                        }
                    }
            }
            .font(.callout)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs + 2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous))
            if flat.isEmpty {
                Text("Nothing matches “\(query)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.m)
            }
            if !hosts.isEmpty {
                section("Hosts")
                ForEach(hosts) { entry in
                    let status = model.hosts.status(for: entry.id)
                    SwitcherHostRow(name: HostMenu.label(entry.id, name: entry.name), symbol: HostMenu.symbol(entry.id, status: status),
                            isSSH: entry.kind == .ssh, failed: SwitcherHostRow.failed(status), isCurrent: entry.id == model.pickedHost,
                            isHighlighted: current == .host(entry.id), value: entry.kind == .ssh ? HostMenu.connectionValue(status) : nil,
                            choose: { choose(entry) })
                }
            }
            ForEach(sections, id: \.section) { group in
                section(group.section.rawValue)
                ForEach(group.entries) { entry in
                    row(entry, highlighted: current == .folder(entry))
                }
            }
            Divider().padding(.vertical, DS.Space.xs)
            Button(action: openFolder) {
                footerLabel(HostMenu.openTitle(model.pickedHost, name: hostName(model.pickedHost)), systemImage: model.pickedHost == .web ? "globe" : "folder.badge.plus")
            }
            .buttonStyle(.plain)
            SettingsLink {
                footerLabel("Manage Hosts…", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
        }
        .padding(DS.Space.s)
        .frame(width: 320)
        .onAppear {
            highlight = SwitcherItem.start(in: flat, query: query, selectedTabID: model.shownTab?.id,
                                   pickedHost: model.pickedHost)
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in
            highlight = SwitcherItem.start(in: lists().flat, query: query, selectedTabID: model.shownTab?.id,
                                   pickedHost: model.pickedHost)
        }
        // Closing or re-pinning a row can shorten the list under the highlight.
        .onChange(of: flat) { _, items in highlight = min(highlight, max(0, items.count - 1)) }
        .animation(DS.Motion.smooth, value: explorer.favorites.map(\.id))
        .animation(DS.Motion.smooth, value: explorer.tabs.map(\.id))
        .animation(DS.Motion.snappy, value: highlight)
        .animation(DS.Motion.smooth, value: flat)
    }


    /// This Mac or a connected ssh host keeps the list open on its folders; the rest go where they go.
    private func choose(_ host: HostsModel.Entry) {
        let pick = HostMenu.pick(host.id, kind: host.kind, status: model.hosts.status(for: host.id))
        if pick.dismisses { dismiss() }
        model.browse(pick)
    }

    private func footerLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
            .contentShape(Rectangle())
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        highlight = (highlight + delta + count) % count
    }

    private func choose(_ entry: SwitcherEntry) {
        dismiss()
        Task { await model.choose(entry) }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.s)
            .padding(.top, DS.Space.xs)
    }

    private func row(_ entry: SwitcherEntry, highlighted: Bool) -> some View {
        let explorer = model.explorer
        let isOpen = entry.isOpen
        let tab = explorer.tabs.first { $0.id == entry.id }
        // A closed folder on an ssh host says how its connection is: picking it connects first.
        let status = model.hosts.status(for: entry.hostID)
        let symbol = isOpen || status == .connected ? SwitcherEntry.symbol(hostID: entry.hostID, path: entry.path, open: isOpen)
            : HostMenu.symbol(entry.hostID, status: status)
        return RootRow(title: entry.title, subtitle: SwitcherEntry.subtitle(hostID: entry.hostID, path: entry.path),
                       symbol: symbol, failed: SwitcherHostRow.failed(status),
                       host: entry.hostID == .local ? nil : entry.hostID == .github ? "GitHub" : entry.hostID == .atlassian ? "Atlassian" : hostName(entry.hostID),
                       isCurrent: isOpen && explorer.selectedTabID == entry.id && entry.hostID == model.pickedHost, isOpen: isOpen,
                       marksOpen: isOpen && entry.section == .favorites, isHighlighted: highlighted,
                       pinned: entry.pinned, notes: tab.map { explorer.folderCountForRoot($0) } ?? 0,
                       choose: { choose(entry) },
                       togglePin: { Task { await explorer.setPinned(entry.id, hostID: entry.hostID, path: entry.path, !entry.pinned) } },
                       close: isOpen ? { explorer.closeTab(entry.id) } : nil)
    }
}

/// A host in the switcher: its symbol (an ssh host's says how its connection is, orange after a failure) and name
/// (teal for an ssh host), the current one filled as the current folder is.
private struct SwitcherHostRow: View {
    let name: String
    let symbol: String
    let isSSH: Bool
    let failed: Bool
    let isCurrent: Bool
    let isHighlighted: Bool
    /// An ssh host's connection, for VoiceOver.
    let value: String?
    let choose: () -> Void
    @State private var hovering = false

    static func failed(_ status: HostsModel.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(failed ? Color.orange : isCurrent ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(name)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isSSH ? Color.teal : Color.primary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs + 1)
        .background {
            if isCurrent || isHighlighted {
                RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous)
                    .fill(Color.accentColor.opacity(isCurrent ? 0.14 : 0.08))
                    .overlay {
                        if isHighlighted {
                            RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                        }
                    }
            } else if hovering {
                RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous).fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(value ?? "")
        .accessibilityAction(named: "Choose \(name)", choose)
    }
}

private struct RootRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    /// The folder's host failed to connect.
    let failed: Bool
    let host: String?
    let isCurrent: Bool
    let isOpen: Bool
    /// A favorite that is open gets a dot under its symbol, as an open app does in the Dock.
    let marksOpen: Bool
    var isHighlighted = false
    let pinned: Bool
    let notes: Int
    let choose: () -> Void
    let togglePin: () -> Void
    let close: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol)
                .foregroundStyle(failed ? Color.orange : isCurrent ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
                .overlay(alignment: .bottom) {
                    if marksOpen {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 4, height: 4)
                            .offset(y: 7)
                            .transition(.opacity)
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Space.xs) {
                    if let host {
                        Text(host).font(.caption.weight(.semibold)).foregroundStyle(.teal)
                    }
                    Text(title)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: DS.Space.xs)
            CountBadge(count: notes)
            // Both controls show only under the pointer, each in a slot of its own on every row, so they line up
            // down the list. A favorite (listed under Favorites) offers to leave them; any other row to join them.
            Button(action: togglePin) {
                Image(systemName: pinned ? "star.slash" : "star")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help(pinned ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(pinned ? "Remove \(title) from Favorites" : "Add \(title) to Favorites")
            Button {
                close?()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(hovering ? 0.08 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering && close != nil ? 1 : 0)
            .allowsHitTesting(hovering && close != nil)
            .accessibilityHidden(close == nil)
            .help("Close \(title)")
            .accessibilityLabel("Close \(title)")
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs + 1)
        .background {
            if isCurrent || isHighlighted {
                // The keyboard's place reads as a ring when it is not the current folder, so the two never blur.
                RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous)
                    .fill(Color.accentColor.opacity(isCurrent ? 0.14 : 0.08))
                    .overlay {
                        if isHighlighted {
                            RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                        }
                    }
            } else if hovering {
                RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous).fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(marksOpen ? "Open" : "")
        .accessibilityAction(named: isOpen ? "Switch to \(title)" : "Open \(title)", choose)
    }
}

extension AppModel {
    /// A folder picked in the switcher: an open one comes to the front; a closed one opens, on an ssh host that
    /// isn't connected after connecting to it (rather than failing with "Not connected"). Its host is picked
    /// first, so the explorer shows the connection while it comes up. A host whose key isn't known yet asks
    /// first; the folder opens once the key is accepted.
    func choose(_ entry: SwitcherEntry) async {
        // The folder in front may already be this one while Web or another host is picked.
        pickedHost = entry.hostID
        if entry.isOpen {
            explorer.selectedTabID = entry.id
        } else if hosts.entry(for: entry.hostID)?.kind == .ssh, explorer.fileSystemProvider(entry.hostID) == nil {
            explorer.pathAwaitingHostKey = nil
            // The file system is what opening needs; the home directory `connect` returns is not.
            _ = await hosts.connect(entry.hostID)
            if explorer.fileSystemProvider(entry.hostID) != nil {
                await explorer.openRoot(hostID: entry.hostID, path: entry.path)
            } else if hosts.pendingHostKey?.hostID == entry.hostID {
                explorer.pathAwaitingHostKey = (entry.hostID, entry.path)
            }
        } else {
            await explorer.openRoot(hostID: entry.hostID, path: entry.path)
        }
    }
}
