import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers
import Viewers

/// Files and folders dragged from Finder onto the window: a folder opens as a root, a file opens (its folder too,
/// when no open root holds it). While a drag hovers, the window says what dropping will do.
struct DropToOpen: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var hoveringFolder = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let local = urls.filter(\.isFileURL)
                guard !local.isEmpty else { return false }
                Task { await open(local) }
                return true
            } isTargeted: { isTargeted in
                targeted = isTargeted
                if isTargeted { hoveringFolder = Self.pasteboardHoldsFolder() }
            }
            .overlay {
                if targeted {
                    DropHint(isFolder: hoveringFolder)
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

    /// Whether the drag in flight carries a folder (the hint names it before the drop).
    private static func pasteboardHoldsFolder() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}

/// The overlay during a drag: an accent outline around the window's content and a small glass card in the middle.
private struct DropHint: View {
    let isFolder: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .padding(DS.Space.s)
            VStack(spacing: DS.Space.s) {
                Image(systemName: isFolder ? "folder.badge.plus" : "doc.badge.plus")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.bounce, value: isFolder)
                Text(isFolder ? "Open folder" : "Open file")
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
