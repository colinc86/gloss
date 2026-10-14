import AppKit
import SwiftUI
import Testing
@testable import Gloss

/// What the sidebar says about a remote host's connection, and what it offers.
@MainActor
struct ConnectionNoticeTests {
    @Test func eachStageSaysWhatIsHappeningAndOffersTheRightAction() {
        typealias C = ConnectionNoticeContent
        #expect(C.make(host: "devbox", status: nil, progress: nil, warning: nil, follow: nil) == nil, "this Mac needs no notice")
        let idle = C.make(host: "devbox", status: .idle, progress: nil, warning: nil, follow: nil)!
        #expect(idle.offersConnect && !idle.isBusy)
        let connecting = C.make(host: "devbox", status: .connecting, progress: "Key accepted, opening session…", warning: nil, follow: nil)!
        #expect(connecting.isBusy && connecting.detail == "Key accepted, opening session…" && connecting.showsDetails)
        let agent = C.make(host: "devbox", status: .waitingForAgent, progress: nil, warning: nil, follow: nil)!
        #expect(agent.kind == .mode && agent.isBusy, "a key agent waiting on the user is a mode, not an error")
        let failed = C.make(host: "devbox", status: .failed("Permission denied (publickey)"), progress: nil, warning: nil, follow: nil)!
        #expect(failed.kind == .warning && failed.offersConnect && failed.detail.contains("publickey"))
        #expect(C.make(host: "devbox", status: .connected, progress: nil, warning: nil, follow: nil) == nil, "a healthy connection is silent")
        #expect(C.make(host: "devbox", status: .connected, progress: nil, warning: "rg not found; search uses grep", follow: nil)?.kind == .warning)
        #expect(C.make(host: "this Mac", status: nil, progress: nil, warning: nil, follow: "Herdr is not running")?.title == "Follow Herdr")
    }

    /// Renders every stage for a visual check (written next to the test run; not compared).
    @Test func rendersEveryStage() throws {
        let states: [(String, HostsModel.Status)] = [
            ("idle", .idle), ("connecting", .connecting), ("agent", .waitingForAgent),
            ("reconnecting", .reconnecting(2)), ("failed", .failed("ssh: connect to host devbox port 22: Operation timed out")),
        ]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-notices")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, status) in states {
            let content = try #require(ConnectionNoticeContent.make(host: "devbox", status: status, progress: "Authenticating with key…", warning: nil, follow: nil))
            let view = ConnectionNotice(content: content) {
                if content.offersConnect { Button("Connect") {}.buttonStyle(.borderedProminent) } else if content.isBusy { Button("Cancel") {} }
            }
            .padding(8)
            .frame(width: 300)
            .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("\(name).png"))
        }
        print("NOTICES at \(folder.path)")
    }
}
