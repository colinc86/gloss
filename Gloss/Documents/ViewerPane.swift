import Core
import SwiftUI
import Viewers

struct ViewerPane: View {
    let session: DocumentSession

    var body: some View {
        VStack(spacing: 0) {
            if let banner = session.banner {
                BannerView(banner: banner, session: session)
                Divider()
            }
            content
            Divider()
            StatusBar(session: session)
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
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let controller):
            Group {
                if let markdown = session.markdown {
                    MarkdownViewerView(controller: markdown)
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
            ContentUnavailableView("Could not open \(session.fileName)", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }

    private func icon(for kind: DocumentKind) -> String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .csv: "tablecells"
        default: "doc"
        }
    }
}

private struct BannerView: View {
    let banner: DocumentSession.Banner
    let session: DocumentSession

    var body: some View {
        HStack {
            Image(systemName: "info.circle")
            Text(message)
            Spacer()
            switch banner {
            case .externalChange:
                Button("Reload") { Task { await session.reloadFromDisk() } }
                Button("Keep Mine") { session.dismissBanner() }
            case .reanchoring:
                Button("Cancel") { session.cancelReanchor() }
            default:
                Button("Dismiss") { session.dismissBanner() }
            }
        }
        .font(.callout)
        .padding(8)
        .background(.yellow.opacity(0.15))
    }

    private var message: String {
        switch banner {
        case .externalChange: "This file changed on disk while you have unsaved edits."
        case .decodedAsLatin1: "This file is not valid UTF-8 and was decoded as Latin-1."
        case .readOnlyLargeFile: "Files over 2 MB open read-only."
        case .tooLarge: "Files over 50 MB are not shown in the text viewer."
        case .nonAtomicSave: "This host cannot rename atomically; saves are not crash-safe."
        case .reanchoring: "Select the note's new range, then press ⌘⇧N to place it."
        }
    }
}

private struct StatusBar: View {
    let session: DocumentSession

    var body: some View {
        HStack(spacing: 12) {
            if session.isDirty {
                Circle().fill(.secondary).frame(width: 7, height: 7)
            }
            Text(session.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let controller = session.textController {
                let position = controller.selectionPosition
                if controller.selection.length > 0 {
                    Text("Ln \(position.start.line), Col \(position.start.col) – Ln \(position.end.line), Col \(position.end.col)")
                } else {
                    Text("Ln \(position.start.line), Col \(position.start.col)")
                }
                Text("\(controller.lineIndex.lineCount) lines")
            }
            Text(session.kind.rawValue)
            if session.isReadOnly { Text("read-only") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// Presents the note popover at `anchorRect`, which providers give in top-left window coordinates.
private struct NotePopoverHost: ViewModifier {
    let session: DocumentSession

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let rect = (session.noteEditor?.anchorRect ?? .zero).offsetBy(dx: -origin.x, dy: -origin.y)
                Color.clear
                    .popover(item: Binding(get: { session.noteEditor }, set: { session.noteEditor = $0 }), attachmentAnchor: .rect(.rect(rect)), arrowEdge: .bottom) { state in
                        NotePopover(
                            state: state,
                            onSave: { edited in Task { await session.commitNote(edited) } },
                            onDelete: { id in Task { await session.deleteNote(id) } },
                            onCancel: { session.noteEditor = nil }
                        )
                    }
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    func notePopover(session: DocumentSession) -> some View {
        modifier(NotePopoverHost(session: session))
    }
}
