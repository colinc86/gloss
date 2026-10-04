import Core
import PDFKit
import SwiftUI

/// Every page as a small sheet, a map of the document and its notes: the current page ringed in the accent colour,
/// and each page with notes marked by their colours and a count. A click goes to the page. Thumbnails render as
/// they scroll into view.
struct PDFThumbnailColumn: View {
    let controller: PDFViewerController
    static let width: CGFloat = 120

    var body: some View {
        let notesByPage = Dictionary(grouping: controller.highlights.filter { $0.state != .resolved }, by: \.page)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(0..<controller.pageCount, id: \.self) { index in
                        PageThumbnail(controller: controller, index: index, isCurrent: index == controller.currentPage,
                                      notes: notesByPage[index] ?? [])
                            .id(index)
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: controller.currentPage) { _, page in
                withAnimation(Motion.smooth) { proxy.scrollTo(page, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(controller.currentPage, anchor: .center) }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pages")
    }
}

private struct PageThumbnail: View {
    let controller: PDFViewerController
    let index: Int
    let isCurrent: Bool
    let notes: [PDFHighlight]
    @State private var image: NSImage?
    @State private var hovering = false

    private static let width: CGFloat = 80

    private var aspect: CGFloat {
        guard let box = controller.document.page(at: index)?.bounds(for: .cropBox), box.width > 0 else { return 1.3 }
        return box.height / box.width
    }

    var body: some View {
        Button { controller.scroll(toPage: index, bounds: nil) } label: {
            VStack(spacing: 6) {
                ZStack {
                    Rectangle().fill(Color.white)
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high)
                    }
                }
                .frame(width: Self.width, height: Self.width * aspect)
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.18), radius: hovering ? 5 : 3, y: 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(isCurrent ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isCurrent ? 2.5 : 0.5)
                        .padding(isCurrent ? -4 : 0)
                }
                .overlay(alignment: .topTrailing) {
                    if !notes.isEmpty { NotesBadge(notes: notes).offset(x: 6, y: -6).transition((AnyTransition.scale.combined(with: .opacity)).calmed) }
                }
                .scaleEffect(hovering && !isCurrent ? 1.03 : 1)
                Text("\(index + 1)")
                    .font(.caption.weight(isCurrent ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
        .animation(Motion.smooth, value: isCurrent)
        .animation(Motion.bouncy, value: notes.count)
        .task(id: index) {
            guard image == nil, let page = controller.document.page(at: index) else { return }
            image = page.thumbnail(of: CGSize(width: Self.width * 2, height: Self.width * 2 * aspect), for: .cropBox)
        }
        .help(notes.isEmpty ? "Page \(index + 1)" : "Page \(index + 1) · \(notes.count) note\(notes.count == 1 ? "" : "s")")
        .accessibilityLabel(notes.isEmpty ? "Page \(index + 1)" : "Page \(index + 1), \(notes.count) note\(notes.count == 1 ? "" : "s")")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// The notes on a page: up to three of their colours as overlapping dots and how many there are.
private struct NotesBadge: View {
    let notes: [PDFHighlight]

    var body: some View {
        let colors = Array(Set(notes.map(\.color))).sorted { $0.rawValue < $1.rawValue }.prefix(3)
        HStack(spacing: 3) {
            HStack(spacing: -3) {
                ForEach(Array(colors), id: \.self) { color in
                    Circle()
                        .fill(Color(nsColor: Theme.color(for: color)))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                }
            }
            Text("\(notes.count)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}
