import AppKit
import SwiftUI
import Viewers

/// The document's bounds are only a positioning anchor. The actual card lives above the window-level paths.
struct ReviewOverlay: NSViewRepresentable {
    nonisolated static let space = "reviewOverlay"
    let model: AppModel
    let session: DocumentSession

    func makeNSView(context: Context) -> Probe {
        Probe(model: model, session: session)
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.place()
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.stop()
    }

    final class Probe: NSView {
        let model: AppModel
        let host: HostingView
        private var installedObserver: NSObjectProtocol?

        init(model: AppModel, session: DocumentSession) {
            self.model = model
            host = HostingView(rootView: Root(model: model, session: session))
            super.init(frame: .zero)
            host.isFlipped = true
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.rootView.onCardFrameChange = { [weak host] in host?.cardFrame = $0 }
            host.rootView.onVisibilityChange = { [weak host] in host?.updateKeyLoop(shown: $0) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityChildren() -> [Any]? { [] }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let installedObserver { NotificationCenter.default.removeObserver(installedObserver) }
            installedObserver = nil
            removeHost()
            if window != nil {
                installedObserver = NotificationCenter.default.addObserver(forName: NoteLinkModel.pathsInstalled, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                }
                place()
            }
        }

        override func layout() {
            super.layout()
            place()
        }

        func place() {
            guard let window else { return }
            guard model.noteLink.installReview(host, in: window) else { removeHost(); return }
            guard let parent = host.superview else { return }
            let rect = convert(bounds, to: parent)
            if host.frame != rect { host.frame = rect }
            host.updateKeyLoop(shown: host.rootView.isPresented)
        }
        func stop() {
            if let installedObserver { NotificationCenter.default.removeObserver(installedObserver) }
            installedObserver = nil
            removeHost()
        }
        func removeHost() {
            host.updateKeyLoop(shown: false)
            host.removeFromSuperview()
        }
    }

    final class HostingView: NSHostingView<Root> {
        var cardFrame: CGRect = .zero
        private let keyLoop = FloatingKeyLoop()
        override var acceptsFirstResponder: Bool { rootView.isPresented && super.acceptsFirstResponder }
        func updateKeyLoop(shown: Bool) { keyLoop.update(host: self, shown: shown) }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard rootView.isPresented, cardFrame.contains(convert(point, from: superview)) else { return nil }
            return super.hitTest(point)
        }
    }

    struct Root: View {
        let model: AppModel
        let session: DocumentSession
        var onCardFrameChange: (CGRect) -> Void = { _ in }
        var onVisibilityChange: (Bool) -> Void = { _ in }
        var isPresented: Bool {
            Self.shouldPresent(active: model.review.isActive, showingSession: model.shownSession === session,
                               compact: model.layout.isCompact, explorerShown: model.layout.isExplorerShown)
        }
        nonisolated static func shouldPresent(active: Bool, showingSession: Bool, compact: Bool, explorerShown: Bool) -> Bool {
            active && showingSession && !(compact && explorerShown)
        }

        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    if isPresented {
                        // The excerpts scroll inside the card rather than the card covering the document.
                        ReviewBar(maxHeight: max(240, proxy.size.height * 0.7), onCardFrameChange: onCardFrameChange)
                            .transition((AnyTransition.move(edge: .bottom).combined(with: .opacity)).calmed)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .coordinateSpace(name: ReviewOverlay.space)
            .environment(model)
            .animation(DS.Motion.smooth, value: isPresented)
            .onChange(of: isPresented, initial: true) { _, shown in onVisibilityChange(shown) }
        }
    }
}
