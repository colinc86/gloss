import AppKit
import Core
import SwiftUI

/// The explorer when Web is the host: an address field (which also narrows the lists as you type), then the pages
/// pinned and the pages visited recently. A double-click or Return opens a page on the host it was visited on;
/// arrows only move the selection. The page in the viewer is selected when it changes.
struct WebPagesSection: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var host: HostID = .local
    @State private var selection: String?
    @FocusState private var focused: Bool

    var body: some View {
        let pages = Self.filtered(model.webPages.pages, by: address)
        let pinned = pages.filter(\.pinned), recent = pages.filter { !$0.pinned }
        VStack(spacing: 0) {
            AddressField(text: $address, host: $host, focus: $focused, prompt: "Address, path, or filter", onOpen: { address = "" }, fallback: {
                // Not an address: Return opens the first page the filter left, as a search field's would.
                guard let first = pinned.first ?? recent.first else { return false }
                model.open(first)
                return true
            })
                .padding(DS.Space.s)
            Divider()
            if model.webPages.pages.isEmpty {
                ContentUnavailableView {
                    Label("No pages yet", systemImage: "globe")
                } description: {
                    Text("Pages you open appear here. Pin the ones you come back to.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pages.isEmpty {
                ContentUnavailableView {
                    Label("No page matches", systemImage: "magnifyingglass")
                } description: {
                    if AddressInput.parse(address, home: model.home(of: host), folder: model.addressFolder(on: host)) != nil {
                        Text("Press Return to open “\(address.trimmingCharacters(in: .whitespaces))”.")
                    } else {
                        Text("No page you visited has “\(address.trimmingCharacters(in: .whitespaces))” in its title or address.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    if !pinned.isEmpty {
                        Section("Pinned") { ForEach(pinned) { row($0) } }
                    }
                    if !recent.isEmpty {
                        Section("Recent") { ForEach(recent) { row($0) } }
                    }
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, ids.count == 1, let page = model.webPages.pages.first(where: { $0.id == id }) {
                        menu(for: page)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let page = model.webPages.pages.first(where: { $0.id == id }) { model.open(page) }
                }
                .animation(DS.Motion.smooth, value: pages.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { host = model.addressHost }
        .onChange(of: shownPageID, initial: true) { _, id in if let id { selection = id } }
    }

    /// The page in the viewer, as a row id.
    private var shownPageID: String? {
        guard let session = model.activeSession, DocumentKindDetector.isWebURL(session.path) else { return nil }
        return WebPage(url: session.path, hostID: session.hostID, lastVisitedAt: .distantPast).id
    }

    private func row(_ page: WebPage) -> some View {
        let address = Core.Document.displayName(of: page.url)
        let via = page.hostID == .web ? nil : model.hosts.entry(for: page.hostID)?.name ?? "another host"
        return VStack(alignment: .leading, spacing: 1) {
            Text(page.title ?? address)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: DS.Space.xs) {
                if let via {
                    Text(via).foregroundStyle(.teal)
                }
                if page.title != nil || via != nil {
                    Text(address)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .tag(page.id)
        .help(page.url + (via.map { " via \($0)" } ?? ""))
    }

    @ViewBuilder
    private func menu(for page: WebPage) -> some View {
        Button { model.open(page) } label: { Label("Open", systemImage: "globe") }
        Divider()
        Button { model.webPages.setPinned(page, !page.pinned) } label: {
            Label(page.pinned ? "Unpin" : "Pin", systemImage: page.pinned ? "pin.slash" : "pin")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(page.url, forType: .string)
            model.flashCopied("Address copied")
        } label: { Label("Copy Address", systemImage: "doc.on.doc") }
        Divider()
        Button(role: .destructive) { model.webPages.remove(page) } label: {
            Label(page.pinned ? "Remove" : "Remove from Recent", systemImage: "minus.circle")
        }
    }

    /// The pages whose title or address holds `query` (case and accents aside), in their order; all for an empty query.
    static func filtered(_ pages: [WebPage], by query: String) -> [WebPage] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return pages }
        return pages.filter { ($0.title ?? "").localizedStandardContains(needle) || $0.url.localizedStandardContains(needle) }
    }
}
