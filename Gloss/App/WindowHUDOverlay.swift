import AppKit
import SwiftUI

/// The original window-wide notifications, hosted above both document paths and the Review card.
struct WindowHUDOverlay: NSViewRepresentable {
    nonisolated static let space = "windowHUDOverlay"
    let model: AppModel
    let panelShown: Bool
    let openSettings: () -> Void

    func makeNSView(context: Context) -> Probe {
        Probe(model: model, panelShown: panelShown, openSettings: openSettings)
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.host.rootView.panelShown = panelShown
        view.host.rootView.openSettings = openSettings
        view.place()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        let model: AppModel
        let host: HostingView
        private var installedObserver: NSObjectProtocol?

        init(model: AppModel, panelShown: Bool, openSettings: @escaping () -> Void) {
            self.model = model
            host = HostingView(rootView: Root(model: model, panelShown: panelShown, openSettings: openSettings))
            super.init(frame: .zero)
            host.isFlipped = true
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.rootView.onToastFrameChange = { [weak host] in host?.toastFrame = $0 }
            host.rootView.onToastVisibilityChange = { [weak host] in host?.updateKeyLoop(shown: $0) }
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
        override func layout() { super.layout(); place() }
        func place() {
            guard let window else { return }
            guard model.noteLink.installHUD(host, in: window) else { removeHost(); return }
            guard let parent = host.superview else { return }
            let rect = convert(bounds, to: parent)
            if host.frame != rect { host.frame = rect }
            host.updateKeyLoop(shown: host.rootView.showsToast)
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
        var toastFrame: CGRect = .zero
        private let keyLoop = FloatingKeyLoop()
        override var acceptsFirstResponder: Bool { rootView.showsToast && super.acceptsFirstResponder }
        func updateKeyLoop(shown: Bool) { keyLoop.update(host: self, shown: shown) }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard rootView.showsToast, toastFrame.contains(convert(point, from: superview)) else { return nil }
            return super.hitTest(point)
        }
    }

    struct Root: View {
        let model: AppModel
        var panelShown: Bool
        var openSettings: () -> Void
        var onToastFrameChange: (CGRect) -> Void = { _ in }
        var onToastVisibilityChange: (Bool) -> Void = { _ in }
        var showsToast: Bool { !panelShown && model.hooks.showsUpdateNotice && !model.hooks.needsUpdate.isEmpty }

        var body: some View {
            ZStack(alignment: .bottom) {
                CopyHUD()
                if !panelShown {
                    AgentsUpdateToast(showSettings: openSettings)
                        .frame(maxWidth: 380)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WindowHUDOverlay.space)) } action: { onToastFrameChange($0) }
                        .padding(DS.Space.m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .coordinateSpace(name: WindowHUDOverlay.space)
            .environment(model)
            .onChange(of: showsToast, initial: true) { _, shown in onToastVisibilityChange(shown) }
        }
    }
}
