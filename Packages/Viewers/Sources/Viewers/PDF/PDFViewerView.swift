import AppKit
import Core
import PDFKit
import SwiftUI

/// Draws region highlights over the PDF and captures rectangle drags in region mode.
final class PDFRegionOverlay: NSView {
    weak var controller: PDFViewerController?
    weak var pdfView: PDFView?
    private var dragStart: (page: PDFPage, point: CGPoint)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard controller?.regionMode == true else { return nil }
        return super.hitTest(point)
    }

    // Flipped like the image canvas, so both draw regions with the same `RegionStyle` code; every conversion goes
    // through `convert(_:from:)`, which accounts for it.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let pdfView else { return }
        let unit: CGFloat = 1   // the overlay is not magnified; PDFView scales the page under it
        for highlight in controller.highlights {
            guard let bounds = highlight.bounds, let page = controller.document.page(at: highlight.page) else { continue }
            let rect = convert(pdfView.convert(bounds, from: page), from: pdfView)
            RegionStyle.drawNote(rect, color: highlight.color, state: highlight.state, selected: highlight.id == controller.selectedNoteID, unit: unit)
        }
        if let region = controller.region, let page = controller.document.page(at: region.page) {
            let rect = convert(pdfView.convert(region.bounds, from: page), from: pdfView)
            RegionStyle.drawSelection(rect, in: bounds, unit: unit, label: "\(Int(region.bounds.width)) × \(Int(region.bounds.height)) pt")
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, let pdfView else { return }
        // The overlay sits beside the PDF view, not above it in the responder chain: hand focus to the PDF view so
        // ⌘C (region copy) reaches it.
        window?.makeFirstResponder(pdfView)
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        if let hit = controller.highlights.last(where: { highlight in
            guard let bounds = highlight.bounds, let page = controller.document.page(at: highlight.page) else { return false }
            return pdfView.convert(bounds, from: page).contains(viewPoint)
        }) {
            controller.selectedNoteID = hit.id
            controller.onNoteClick(hit.id)
            needsDisplay = true
            return
        }
        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }
        dragStart = (page, pdfView.convert(viewPoint, to: page))
        controller.region = nil
        controller.selectedNoteID = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let pdfView, let start = dragStart else { return }
        let point = pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: start.page)
        let rect = CGRect(x: min(start.point.x, point.x), y: min(start.point.y, point.y), width: abs(point.x - start.point.x), height: abs(point.y - start.point.y))
        controller.region = (controller.document.index(for: start.page), rect.intersection(start.page.bounds(for: .cropBox)))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        if let region = controller?.region, region.bounds.width < 3 || region.bounds.height < 3 { controller?.region = nil }
        needsDisplay = true
    }
}

/// A PDFView whose Copy takes a drawn region as an image; with no region it copies selected text as usual.
final class RegionCopyingPDFView: PDFView {
    weak var regionController: PDFViewerController?

    override func copy(_ sender: Any?) {
        guard let controller = regionController, let region = controller.region,
              let rendered = controller.renderPNG(page: region.page, bounds: region.bounds) else {
            return super.copy(sender)
        }
        let item = NSPasteboardItem()
        item.setData(rendered.data, forType: .png)
        if let image = NSImage(data: rendered.data), let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        controller.copyCount += 1
    }

    /// PDFKit's `validateMenuItem:` (Objective-C, not visible to Swift); everything except Copy still goes to it, so
    /// zoom limits, page navigation, and the display-mode checkmarks keep working.
    private typealias Validate = @convention(c) (AnyObject, Selector, NSMenuItem) -> ObjCBool
    private static let pdfKitValidate: Validate? = {
        let selector = NSSelectorFromString("validateMenuItem:")
        guard let method = class_getInstanceMethod(PDFView.self, selector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: Validate.self)
    }()

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return regionController?.region != nil || currentSelection != nil }
        return Self.pdfKitValidate?(self, NSSelectorFromString("validateMenuItem:"), menuItem).boolValue ?? true
    }
}

public final class PDFContainerView: NSView {
    let pdfView = RegionCopyingPDFView()
    let overlay = PDFRegionOverlay()

    override public init(frame: NSRect) {
        super.init(frame: frame)
        pdfView.autoresizingMask = [.width, .height]
        overlay.autoresizingMask = [.width, .height]
        addSubview(pdfView)
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func layout() {
        super.layout()
        pdfView.frame = bounds
        overlay.frame = bounds
    }
}

public struct PDFViewerView: NSViewRepresentable {
    public let controller: PDFViewerController

    public init(controller: PDFViewerController) {
        self.controller = controller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public func makeNSView(context: Context) -> PDFContainerView {
        let container = PDFContainerView(frame: .zero)
        let pdfView = container.pdfView
        pdfView.document = controller.document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        // Pages as sheets on the under-page backdrop, as in Preview and the image viewer: a page's edge is part of
        // what is being annotated.
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        container.overlay.controller = controller
        container.pdfView.regionController = controller
        container.overlay.pdfView = pdfView
        context.coordinator.attach(container: container)
        return container
    }

    public func updateNSView(_ nsView: PDFContainerView, context: Context) {
        context.coordinator.sync()
    }

    public static func dismantleNSView(_ nsView: PDFContainerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    public final class Coordinator {
        let controller: PDFViewerController
        private weak var container: PDFContainerView?
        private var observers: [any NSObjectProtocol] = []
        /// Each note's rects in page space, worked out once per set of highlights (the document never changes); a
        /// scroll only converts and clips them.
        private var notePageRects: [NoteID: (page: Int, rects: [CGRect])] = [:]
        private var notePageRectsFor: [PDFHighlight]?
        private var appliedScroll = 0

        init(controller: PDFViewerController) {
            self.controller = controller
        }

        func attach(container: PDFContainerView) {
            self.container = container
            let pdfView = container.pdfView
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.selectionChanged() }
            })
            for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
                observers.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.viewChanged() }
                })
            }
            if let clip = pdfView.subviews.compactMap({ $0 as? NSScrollView }).first?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.container?.overlay.needsDisplay = true
                        self?.controller.noteGeometry.changed()
                    }
                })
            }
            controller.onHighlightsChange = { [weak self] in self?.sync() }
            controller.rectProvider = { [weak self] page, bounds in
                guard let self, let container = self.container, let pdfPage = self.controller.document.page(at: page) else { return nil }
                return container.pdfView.topLeftWindowRect(container.pdfView.convert(bounds, from: pdfPage))
            }
            controller.noteGeometry.viewport = { [weak self] in
                guard let pdfView = self?.container?.pdfView, pdfView.window != nil else { return nil }
                return pdfView.topLeftWindowRect(pdfView.bounds)
            }
            controller.noteGeometry.visibleNoteRects = { [weak self] in self?.visibleNoteRects() ?? [:] }
        }

        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }

        func sync() {
            guard let container else { return }
            _ = controller.region?.bounds
            _ = controller.selectedNoteID
            container.overlay.needsDisplay = true
            applyTextHighlights()
            controller.noteGeometry.changed()
            if appliedScroll != controller.pendingScrollVersion, let target = controller.pendingScroll {
                appliedScroll = controller.pendingScrollVersion
                if let page = controller.document.page(at: target.page) {
                    if let bounds = target.bounds {
                        container.pdfView.go(to: bounds, on: page)
                    } else {
                        container.pdfView.go(to: page)
                    }
                }
            }
        }

        private func applyTextHighlights() {
            guard let pdfView = container?.pdfView else { return }
            var selections: [PDFSelection] = []
            for highlight in controller.highlights where highlight.bounds == nil {
                guard let text = highlight.text else { continue }
                if let selection = controller.selection(matching: text, onPage: highlight.page, occurrence: highlight.occurrence) {
                    selection.color = Theme.color(for: highlight.color).withAlphaComponent(0.35)
                    selections.append(selection)
                }
            }
            pdfView.highlightedSelections = selections.isEmpty ? nil : selections
        }

        private func selectionChanged() {
            guard let pdfView = container?.pdfView else { return }
            guard let selection = pdfView.currentSelection, let page = selection.pages.first,
                  let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                controller.textSelection = nil
                return
            }
            controller.textSelection = (controller.document.index(for: page), selection.bounds(for: page), text)
            controller.region = nil
            container?.overlay.needsDisplay = true
        }

        private func viewChanged() {
            guard let pdfView = container?.pdfView else { return }
            if let page = pdfView.currentPage { controller.currentPage = controller.document.index(for: page) }
            container?.overlay.needsDisplay = true
            controller.noteGeometry.changed()
        }

        /// Region notes as their box; text notes as the lines of the text they were made on.
        private func visibleNoteRects() -> [NoteID: [CGRect]] {
            guard let pdfView = container?.pdfView, pdfView.window != nil else { return [:] }
            let visible = pdfView.bounds
            let onScreen = Set(pdfView.visiblePages.map { controller.document.index(for: $0) })
            var result: [NoteID: [CGRect]] = [:]
            if notePageRectsFor != controller.highlights {
                notePageRectsFor = controller.highlights
                notePageRects = [:]
                for highlight in controller.highlights {
                    guard let page = controller.document.page(at: highlight.page) else { continue }
                    if let bounds = highlight.bounds {
                        notePageRects[highlight.id] = (highlight.page, [bounds])
                    } else if let text = highlight.text, let selection = controller.selection(matching: text, onPage: highlight.page, occurrence: highlight.occurrence) {
                        notePageRects[highlight.id] = (highlight.page, selection.selectionsByLine().map { $0.bounds(for: page) })
                    }
                }
            }
            for (id, entry) in notePageRects where onScreen.contains(entry.page) {
                guard let page = controller.document.page(at: entry.page) else { continue }
                let rects = entry.rects.compactMap { rect -> CGRect? in
                    let clipped = pdfView.convert(rect, from: page).intersection(visible)
                    return clipped.isNull || clipped.isEmpty ? nil : pdfView.topLeftWindowRect(clipped)
                }
                if !rects.isEmpty { result[id] = rects }
            }
            return result
        }
    }
}

/// PDF with a page indicator and region-mode toggle.
public struct PDFViewerPane: View {
    public let controller: PDFViewerController

    public init(controller: PDFViewerController) {
        self.controller = controller
    }

    public var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            ViewerToolbar {
                if controller.pageCount > 1 {
                    ThumbnailsToggle(isOn: $controller.showsThumbnails)
                }
                Label("Page \(controller.currentPage + 1) of \(controller.pageCount)", systemImage: "doc.richtext")
                    .contentTransition(.numericText(value: Double(controller.currentPage)))
                if let region = controller.region {
                    Text("Region \(Int(region.bounds.width)) × \(Int(region.bounds.height)) pt")
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
            } trailing: {
                CopiedBadge(count: controller.copyCount)
                ZStack(alignment: .trailing) {
                    if controller.regionMode {
                        ToolHints(controller.region == nil
                                  ? [ToolHint(symbol: "rectangle.dashed", "Drag a region on a page")]
                                  : [ToolHint(keys: ["⌘", "C"], "Copy"), ToolHint(symbol: "rectangle.dashed", "Drag again to redraw")])
                            .transition(.opacity)
                    }
                }
                ModeSwitch([
                    .init(false, "Text", symbol: "text.cursor"),
                    .init(true, "Region", symbol: "rectangle.dashed"),
                ], selection: $controller.regionMode)
                .help("Select text, or drag a rectangle on a page")
            }
            .animation(Motion.smooth, value: controller.currentPage)
            .animation(Motion.smooth, value: controller.regionMode)
            .animation(Motion.smooth, value: controller.region == nil)
            HStack(spacing: 0) {
                if controller.showsThumbnails && controller.pageCount > 1 {
                    PDFThumbnailColumn(controller: controller)
                        .transition((AnyTransition.move(edge: .leading).combined(with: .opacity)).calmed)
                    Divider()
                }
                PDFViewerView(controller: controller)
                    .overlay(alignment: .bottom) { PagePill(page: controller.currentPage, count: controller.pageCount) }
            }
            .animation(Motion.smooth, value: controller.showsThumbnails)
        }
    }
}

/// Shows or hides the page thumbnails; drawn filled while they show, as toggles here say what is true now.
struct ThumbnailsToggle: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: isOn ? "sidebar.squares.left" : "sidebar.left")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isOn ? Color.accentColor : (hovering ? .primary : .secondary))
                .frame(width: 22, height: 20)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
        .help(isOn ? "Hide page thumbnails" : "Show page thumbnails")
        .accessibilityLabel("Page thumbnails")
        .accessibilityValue(isOn ? "Shown" : "Hidden")
    }
}

/// "3 / 12" floating over the bottom of the document while the pages move, as Preview does; it fades out once
/// scrolling settles. Not on open (the toolbar already says where you are), and never for one page.
struct PagePill: View {
    let page: Int
    let count: Int
    @State private var visible = false
    @State private var appearedAt = Date()

    var body: some View {
        ZStack {
            if visible {
                Text("\(page + 1) / \(count)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(page)))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .transition((AnyTransition.opacity.combined(with: .offset(y: Motion.isReduced ? 0 : 6))).calmed)
                    .accessibilityHidden(true)
            }
        }
        .padding(.bottom, 18)
        .animation(Motion.smooth, value: visible)
        .animation(Motion.snappy, value: page)
        .allowsHitTesting(false)
        .onAppear { appearedAt = Date() }
        .task(id: page) {
            // Opening (including a jump straight to a note's page) settles within a moment; only later moves count.
            guard Date().timeIntervalSince(appearedAt) > 0.8, count > 1 else { return }
            visible = true
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            visible = false
        }
    }
}
