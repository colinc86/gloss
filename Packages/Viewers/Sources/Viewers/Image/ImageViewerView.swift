import AppKit
import Core
import SwiftUI

public struct ImageViewerView: NSViewRepresentable {
    public let controller: ImageViewerController

    public init(controller: ImageViewerController) {
        self.controller = controller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let canvas = ImageCanvasView(controller: controller)
        let scroll = NSScrollView()
        // Centres an image smaller than the pane instead of pinning it to the top-left corner.
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 32
        // A quiet backdrop that separates the picture from the window, whatever its colours.
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.drawsBackground = true
        context.coordinator.attach(canvas: canvas, scrollView: scroll)
        // On open, shrink a large image to fit but show a small one at actual size (centred), as Preview does:
        // enlarging a 360-pixel diagram to fill the pane only blurs it.
        DispatchQueue.main.async { context.coordinator.fitWithoutEnlarging() }
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.sync()
    }

    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    public final class Coordinator {
        let controller: ImageViewerController
        private weak var canvas: ImageCanvasView?
        private weak var scrollView: NSScrollView?
        private var appliedZoom = 0
        private var observer: (any NSObjectProtocol)?
        private var frameObserver: (any NSObjectProtocol)?
        private var boundsObserver: (any NSObjectProtocol)?
        /// Until the user zooms, the image keeps fitting the pane as it settles and resizes.
        private var autoFit = true

        init(controller: ImageViewerController) {
            self.controller = controller
        }

        func attach(canvas: ImageCanvasView, scrollView: NSScrollView) {
            self.canvas = canvas
            self.scrollView = scrollView
            controller.rectProvider = { [weak self] rect in
                guard let self, let canvas = self.canvas else { return nil }
                return canvas.topLeftWindowRect(rect)
            }
            controller.onHighlightsChange = { [weak canvas, weak controller] in
                canvas?.needsDisplay = true
                controller?.noteGeometry.changed()
            }
            controller.noteGeometry.viewport = { [weak scrollView] in
                guard let scrollView, scrollView.window != nil else { return nil }
                return scrollView.contentView.topLeftWindowRect(scrollView.contentView.bounds)
            }
            controller.noteGeometry.visibleNoteRects = { [weak canvas, weak controller] in
                guard let canvas, let controller, canvas.window != nil else { return [:] }
                let visible = canvas.visibleRect
                var result: [NoteID: [CGRect]] = [:]
                for highlight in controller.highlights {
                    let clipped = highlight.rect.intersection(visible)
                    if !clipped.isNull, !clipped.isEmpty, let rect = canvas.topLeftWindowRect(clipped) { result[highlight.id] = [rect] }
                }
                return result
            }
            // Scrolling and zooming both move the clip view's bounds.
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak controller] _ in
                MainActor.assumeIsolated { controller?.noteGeometry.changed() }
            }
            observer = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self, weak canvas] _ in
                MainActor.assumeIsolated {
                    self?.autoFit = false   // a pinch is a choice
                    self?.publishMagnification()
                    canvas?.needsDisplay = true
                }
            }
            // The first fit can run before the pane has its final size (opening into an existing window); refit
            // whenever the size changes while the zoom is still automatic.
            scrollView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.autoFit else { return }
                    self.fitWithoutEnlarging()
                }
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil
            observer = nil
            frameObserver = nil
        }

        func sync() {
            // Touch the drawn state so SwiftUI tracks it; the canvas reads it again in draw().
            _ = controller.highlights.count
            _ = controller.selection
            _ = controller.selectedNoteID
            canvas?.needsDisplay = true
            if appliedZoom != controller.pendingZoomVersion, let command = controller.pendingZoom {
                appliedZoom = controller.pendingZoomVersion
                apply(command)
            }
        }

        func fit() {
            apply(.fit)
        }

        func fitWithoutEnlarging() {
            guard let scrollView, let canvas, scrollView.contentSize.width > 1, scrollView.contentSize.height > 1 else { return }
            scrollView.magnify(toFit: canvas.bounds)
            if scrollView.magnification > 1 {
                scrollView.setMagnification(1, centeredAt: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
            }
            canvas.needsDisplay = true
            publishMagnification()
        }

        private func publishMagnification() {
            guard let scrollView, abs(controller.magnification - scrollView.magnification) > 0.001 else { return }
            controller.magnification = scrollView.magnification
        }

        private func apply(_ command: ImageViewerController.ZoomCommand) {
            guard let scrollView, let canvas else { return }
            let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            // Any zoom command but Fit hands the zoom level to the user.
            autoFit = command == .fit
            switch command {
            case .fit:
                scrollView.magnify(toFit: canvas.bounds)
            case .actualSize:
                scrollView.setMagnification(1, centeredAt: center)
            case .zoomIn:
                scrollView.setMagnification(min(scrollView.maxMagnification, scrollView.magnification * 1.5), centeredAt: center)
            case .zoomOut:
                scrollView.setMagnification(max(scrollView.minMagnification, scrollView.magnification / 1.5), centeredAt: center)
            }
            canvas.needsDisplay = true
            publishMagnification()
        }
    }
}

/// Image canvas with a zoom strip.
public struct ImageViewerPane: View {
    public let controller: ImageViewerController

    public init(controller: ImageViewerController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            ViewerToolbar {
                Label("\(controller.image.width) × \(controller.image.height) px", systemImage: "photo")
                if let selection = controller.selection {
                    Text("Region \(Int(selection.minX)), \(Int(selection.minY)) · \(Int(selection.width)) × \(Int(selection.height))")
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
            } trailing: {
                CopiedBadge(count: controller.copyCount)
                ZStack(alignment: .trailing) {
                    if controller.selection != nil {
                        ToolHints([ToolHint(keys: ["⌘", "C"], "Copy", explained: "Copy the region as an image"), ToolHint(keys: ["esc"], "Clear", explained: "Clear the region"), ToolHint(symbol: "rectangle.dashed", "Drag again to redraw", explained: "Drag again to draw a new region")])
                            .transition(.opacity)
                    } else {
                        ToolHints([ToolHint(symbol: "rectangle.dashed", "Drag a region")]
                                  + (controller.highlights.isEmpty ? [] : [ToolHint(symbol: "cursorarrow.click", "Click a note to open it")]))
                            .transition(.opacity)
                    }
                }
                ToolGroup {
                    Button { controller.zoom(.zoomOut) } label: { Image(systemName: "minus") }
                        .keyboardShortcut("-", modifiers: [.command])
                        .help("Zoom out")
                    ToolDivider()
                    Button { controller.zoom(.actualSize) } label: {
                        Text("\(Int((controller.magnification * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(minWidth: 38)
                            .contentTransition(.numericText(value: controller.magnification))
                    }
                    .keyboardShortcut("1", modifiers: [.command])
                    .help("Actual size")
                    ToolDivider()
                    Button { controller.zoom(.zoomIn) } label: { Image(systemName: "plus") }
                        .keyboardShortcut("=", modifiers: [.command])
                        .help("Zoom in")
                }
                .animation(Motion.snappy, value: controller.magnification)
                ToolGroup {
                    Button { controller.zoom(.fit) } label: {
                        ViewThatFits(in: .horizontal) {
                            Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left").fixedSize()
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                    .accessibilityLabel("Fit")
                        .keyboardShortcut("0", modifiers: [.command])
                        .help("Fit the image to the pane")
                }
            }
            .animation(Motion.smooth, value: controller.selection == nil)
            ImageViewerView(controller: controller)
        }
    }
}

/// Keeps a document smaller than the visible area centred in it (both axes), for images and other canvases.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}
