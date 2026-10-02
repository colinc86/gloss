import AppKit
import Core

/// Copies the packet text to the general pasteboard. Attachments stay in the local cache.
struct ClipboardTransport: Transport {
    let kind = TransportKind.clipboard

    static let target = AgentTarget(transport: .clipboard, hostID: .local, label: "Clipboard", detail: "Paste into any terminal", identityJSON: "{}")

    func discoverTargets() async throws -> [AgentTarget] {
        [Self.target]
    }

    func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(packet.text, forType: .string)
        }
        return DeliveryReceipt(detail: attachments.isEmpty ? "copied" : "copied; attachments are local paths")
    }
}
