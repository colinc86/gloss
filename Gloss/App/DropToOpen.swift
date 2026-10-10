import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers
import Viewers

/// Files and folders dragged from Finder onto the window: a folder opens as a root, a file opens (its folder too,
/// when no open root holds it). A link dragged from a browser opens as a page, as typing its address would. While a
/// drag hovers, the window says what dropping will do.
struct DropToOpen: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var hovering = DropHint.Kind.file

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let local = urls.filter(\.isFileURL)
                let pages = Self.webPages(in: urls)
                guard !local.isEmpty || !pages.isEmpty else { return false }
                Task { await open(local) }
                for page in pages { model.openWebPage(page, via: model.via(for: page, on: model.addressHost, chosen: false)) }
                return true
            } isTargeted: { isTargeted in
                targeted = isTargeted
                if isTargeted { hovering = Self.pasteboardKind() }
            }
            .overlay {
                if targeted {
                    DropHint(kind: hovering)
                        .transition((AnyTransition.opacity.combined(with: .scale(scale: 0.98))).calmed)
                        .allowsHitTesting(false)
                }
            }
            .animation(DS.Motion.snappy, value: targeted)
    }

    private func open(_ urls: [URL]) async {
        for url in urls {
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                await model.explorer.openRoot(hostID: .local, path: path)
            } else {
                await model.openRootIfNeeded(hostID: .local, containing: path)
                model.openDocument(hostID: .local, path: path)
            }
        }
    }

    /// The web pages among dropped URLs: http and https links, as a browser drags them.
    nonisolated static func webPages(in urls: [URL]) -> [URL] {
        urls.filter { !$0.isFileURL && ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    /// What the drag in flight carries, so the hint names it before the drop.
    private static func pasteboardKind() -> DropHint.Kind {
        let pasteboard = NSPasteboard(name: .drag)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if urls.contains(where: { $0.isFileURL && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) { return .folder }
        if !urls.contains(where: \.isFileURL), !webPages(in: urls).isEmpty { return .page }
        return .file
    }
}

/// The overlay during a drag: an accent outline around the window's content and a small glass card in the middle.
struct DropHint: View {
    enum Kind { case file, folder, page }
    let kind: Kind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .padding(DS.Space.s)
            VStack(spacing: DS.Space.s) {
                Image(systemName: kind == .folder ? "folder.badge.plus" : kind == .page ? "globe" : "doc.badge.plus")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.bounce, value: kind)
                Text(kind == .folder ? "Open folder" : kind == .page ? "Open page" : "Open file")
                    .font(.headline)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        }
        .accessibilityHidden(true)
    }
}

extension View {
    func dropToOpen() -> some View { modifier(DropToOpen()) }
}
