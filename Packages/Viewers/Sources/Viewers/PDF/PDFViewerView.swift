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

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let pdfView else { return }
        for highlight in controller.highlights {
            guard let bounds = highlight.bounds, let page = controller.document.page(at: highlight.page) else { continue }
            let rect = convert(pdfView.convert(bounds, from: page), from: pdfView)
            let color = Theme.color(for: highlight.color)
            let path = NSBezierPath(rect: rect)
            color.withAlphaComponent(highlight.state == .resolved ? 0.08 : 0.2).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = highlight.id == controller.selectedNoteID ? 2.5 : 1.5
            if highlight.state == .orphaned { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()
        }
        if let region = controller.region, let page = controller.document.page(at: region.page) {
            let rect = convert(pdfView.convert(region.bounds, from: page), from: pdfView)
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            rect.fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: rect).stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, let pdfView else { return }
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

public final class PDFContainerView: NSView {
    let pdfView = PDFView()
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
        pdfView.backgroundColor = .windowBackgroundColor
        container.overlay.controller = controller
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
                    MainActor.assumeIsolated { self?.container?.overlay.needsDisplay = true }
                })
            }
            controller.rectProvider = { [weak self] page, bounds in
                guard let self, let container = self.container, let pdfPage = self.controller.document.page(at: page) else { return nil }
                return container.convert(container.pdfView.convert(bounds, from: pdfPage), from: container.pdfView)
            }
        }

        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }

        func sync() {
            guard let container else { return }
            container.overlay.needsDisplay = true
            applyTextHighlights()
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
                guard let text = highlight.text, let page = controller.document.page(at: highlight.page) else { continue }
                if let selection = page.document?.findString(text, withOptions: [.caseInsensitive]).first(where: { $0.pages.contains(page) }) {
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
            HStack(spacing: 12) {
                Text("Page \(controller.currentPage + 1) of \(controller.pageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let region = controller.region {
                    Text("Region \(Int(region.bounds.minX)),\(Int(region.bounds.minY)) \(Int(region.bounds.width))×\(Int(region.bounds.height)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: $controller.regionMode) {
                    Label("Region", systemImage: "rectangle.dashed")
                }
                .toggleStyle(.button)
                .help("Drag a rectangle on a page instead of selecting text")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            PDFViewerView(controller: controller)
        }
    }
}
