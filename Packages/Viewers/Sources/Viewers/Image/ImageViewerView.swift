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
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 32
        scroll.backgroundColor = .windowBackgroundColor
        scroll.drawsBackground = true
        context.coordinator.attach(canvas: canvas, scrollView: scroll)
        DispatchQueue.main.async { context.coordinator.fit() }
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.sync()
    }

    @MainActor
    public final class Coordinator {
        let controller: ImageViewerController
        private weak var canvas: ImageCanvasView?
        private weak var scrollView: NSScrollView?
        private var appliedZoom = 0
        private var observer: (any NSObjectProtocol)?

        init(controller: ImageViewerController) {
            self.controller = controller
        }

        func attach(canvas: ImageCanvasView, scrollView: NSScrollView) {
            self.canvas = canvas
            self.scrollView = scrollView
            controller.rectProvider = { [weak self] rect in
                guard let self, let canvas = self.canvas, let scrollView = self.scrollView else { return nil }
                return canvas.convert(rect, to: scrollView)
            }
            observer = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak canvas] _ in
                MainActor.assumeIsolated { canvas?.needsDisplay = true }
            }
        }

        func sync() {
            canvas?.needsDisplay = true
            if appliedZoom != controller.pendingZoomVersion, let command = controller.pendingZoom {
                appliedZoom = controller.pendingZoomVersion
                apply(command)
            }
        }

        func fit() {
            apply(.fit)
        }

        private func apply(_ command: ImageViewerController.ZoomCommand) {
            guard let scrollView, let canvas else { return }
            let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
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
            HStack(spacing: 10) {
                Text("\(controller.image.width) × \(controller.image.height)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let selection = controller.selection {
                    Text("Region \(Int(selection.minX)),\(Int(selection.minY)) \(Int(selection.width))×\(Int(selection.height))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fit") { controller.zoom(.fit) }.keyboardShortcut("0", modifiers: [.command])
                Button("100%") { controller.zoom(.actualSize) }.keyboardShortcut("1", modifiers: [.command])
                Button { controller.zoom(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }.keyboardShortcut("-", modifiers: [.command])
                Button { controller.zoom(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }.keyboardShortcut("=", modifiers: [.command])
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ImageViewerView(controller: controller)
        }
    }
}
