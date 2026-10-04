import Core
import Foundation
import Testing
@testable import Transports

struct TmuxTransportTests {
    @Test func parsesPaneListingsAndBuildsScripts() {
        let panes = TmuxTransport.parsePanes("main:1.1\tnode\t/Users/me/repo\nother:0.2\tzsh\t/tmp/with\ttab\n\n")
        #expect(panes == [TmuxPane(target: "main:1.1", command: "node", path: "/Users/me/repo"), TmuxPane(target: "other:0.2", command: "zsh", path: "/tmp/with\ttab")])
        #expect(panes[0].looksLikeAgent && !panes[1].looksLikeAgent)
        let script = TmuxTransport.deliverScript(tmux: "tmux -L 'x'", target: "it's:1.1")
        #expect(script.contains("display-message -p -t 'it'\\''s:1.1' '#{pane_current_command}'"), "the pane is asked what it runs before anything is typed")
        #expect(script.hasSuffix("b=\"cc-$$\"; tmux -L 'x' load-buffer -b \"$b\" - && { tmux -L 'x' paste-buffer -p -d -b \"$b\" -t 'it'\\''s:1.1' || { tmux -L 'x' delete-buffer -b \"$b\" 2>/dev/null; false; }; } && tmux -L 'x' send-keys -t 'it'\\''s:1.1' Enter"))
        let target = TmuxTransport.target(for: panes[0], hostID: .local, hostLabel: nil)
        #expect(TmuxTransport.pane(from: target) == panes[0])
        #expect(target.label == "main:1.1 · node")
    }

    @Test(.enabled(if: TestGates.tmux))
    func pastesAPacketIntoAPrivateServerPane() async throws {
        let tmux = TmuxTransport.locateTmux()!
        let socket = "gloss-test-\(UUID().uuidString.prefix(6))"
        // A private server (-L) with one pane running `cat`, so the pasted text is echoed back on screen.
        #expect(TestGates.run(tmux, ["-L", socket, "new-session", "-d", "-s", "gloss-verify", "-x", "120", "-y", "30", "cat"]).status == 0)
        defer { TestGates.run(tmux, ["-L", socket, "kill-server"]) }
        try await Task.sleep(for: .milliseconds(300))

        let transport = TmuxTransport(registry: ConnectionRegistry(), localTmuxPath: tmux, socketName: socket)
        let targets = try await transport.discoverTargets()
        // Window and pane numbers follow the user's base-index, so match the session only.
        let target = try #require(targets.first { TmuxTransport.pane(from: $0)?.target.hasPrefix("gloss-verify:") == true })
        let pane = try #require(TmuxTransport.pane(from: target))
        #expect(pane.command == "cat")

        let note = PacketNote(noteID: NoteID.new(), agentPath: "/tmp/demo/README.md", source: .markdown, anchor: .wholeFile, comment: "first line\nsecond line")
        let packet = PacketBuilder.build([note])
        let receipt = try await transport.deliver(packet, attachments: [], to: target)
        #expect(receipt.detail == "pasted into \(pane.target)")

        var screen = ""
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(150))
            screen = TestGates.run(tmux, ["-L", socket, "capture-pane", "-p", "-t", pane.target]).stdout
            if screen.contains("second line") { break }
        }
        #expect(screen.contains("File: /tmp/demo/README.md"), "the packet header reached the pane: \(screen)")
        #expect(screen.contains("second line"), "the whole multi-line packet was pasted, not submitted at the first newline")
        #expect(TestGates.run(tmux, ["-L", socket, "list-buffers"]).stdout.isEmpty, "paste-buffer -d removed the buffer")
    }

    /// A pane running a shell gets nothing: the paste and its Enter would run the packet's lines as commands.
    @Test(.enabled(if: TestGates.tmux))
    func refusesAPaneRunningAShell() async throws {
        let tmux = TmuxTransport.locateTmux()!
        let socket = "gloss-test-\(UUID().uuidString.prefix(6))"
        let marker = NSTemporaryDirectory() + "gloss-shell-\(UUID().uuidString.prefix(6))"
        #expect(TestGates.run(tmux, ["-L", socket, "new-session", "-d", "-s", "gloss-shell", "-x", "120", "-y", "30", "/bin/sh"]).status == 0)
        defer {
            TestGates.run(tmux, ["-L", socket, "kill-server"])
            try? FileManager.default.removeItem(atPath: marker)
        }
        try await Task.sleep(for: .milliseconds(300))
        let transport = TmuxTransport(registry: ConnectionRegistry(), localTmuxPath: tmux, socketName: socket)
        let target = try #require(try await transport.discoverTargets().first { TmuxTransport.pane(from: $0)?.target.hasPrefix("gloss-shell:") == true })
        // A comment whose second line is a command: in a shell it would run.
        let note = PacketNote(noteID: NoteID.new(), agentPath: "/tmp/demo/README.md", source: .markdown, anchor: .wholeFile, comment: "x\ntouch \(marker)")
        await #expect(throws: DeliveryError.self) { _ = try await transport.deliver(PacketBuilder.build([note]), attachments: [], to: target) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: marker), "nothing ran in the shell")
        #expect(TestGates.run(tmux, ["-L", socket, "list-buffers"]).stdout.isEmpty)
    }
}
