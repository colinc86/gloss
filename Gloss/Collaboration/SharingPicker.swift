import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let glossReview = UTType(exportedAs: "com.cnc.gloss.document", conformingTo: .package)
}

/// Each picker receives one URL. Mode restriction makes Send Copy's detached instance unambiguous.
struct SharingPickerButton: NSViewRepresentable {
    let url: URL
    let copy: Bool
    let began: () -> Void
    let finished: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: copy ? "Send Copy…" : "Choose People…", target: context.coordinator, action: #selector(Coordinator.show(_:)))
        button.bezelStyle = .rounded
        button.sendAction(on: .leftMouseDown)
        button.setAccessibilityLabel(copy ? "Send a detached copy of this review" : "Invite people to collaborate on this review")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.url = url; context.coordinator.copy = copy; context.coordinator.finished = finished; context.coordinator.began = began
    }
    @MainActor final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        private static var active: [UUID: Coordinator] = [:]
        private let token = UUID()
        var url: URL?
        var copy = false
        var began: () -> Void = {}
        var finished: (String?) -> Void = { _ in }
        var picker: NSSharingServicePicker?
        weak var anchor: NSView?
        @objc func show(_ sender: NSButton) {
            guard let url else { return }
            began()
            Self.active[token] = self
            anchor = sender
            let picker = NSSharingServicePicker(items: [url])
            self.picker = picker; picker.delegate = self
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
        func sharingServicePickerCollaborationModeRestrictions(_ sharingServicePicker: NSSharingServicePicker) -> [NSSharingServicePicker.CollaborationModeRestriction]? {
            [.init(disabledMode: copy ? .collaborate : .sendCopy)]
        }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if service == nil { complete(nil) }
        }
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { complete(nil) }
        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) { complete(error.localizedDescription) }
        private func complete(_ error: String?) {
            Self.active[token] = nil
            picker = nil
            finished(error)
            if copy, let url {
                let folder = url.deletingLastPathComponent()
                Task.detached { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }
}
