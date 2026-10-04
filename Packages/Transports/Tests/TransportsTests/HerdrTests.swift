import Core
import Foundation
import Testing
@testable import Transports

struct HerdrTests {
    @Test func buildsRequestsAndParsesReplies() throws {
        let line = try HerdrClient.requestLine(method: "ping", params: [:])
        let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        #expect(object?["method"] as? String == "ping" && (object?["id"] as? String)?.isEmpty == false && line.last == 0x0A)
        #expect(throws: HerdrError.self) { try HerdrClient.requestLine(method: "agent.prompt", params: ["text": String(repeating: "x", count: 1_100_000)]) }

        let ok = try HerdrClient.result(from: Data(#"{"id":"1","result":{"type":"pong","version":"0.9.3","protocol":22}}"#.utf8))
        #expect(ok["type"] as? String == "pong")
        #expect(throws: HerdrError.server(code: "agent_blocked", message: "busy")) {
            try HerdrClient.result(from: Data(#"{"id":"1","error":{"code":"agent_blocked","message":"busy"}}"#.utf8))
        }
        #expect(throws: HerdrError.eventsLost) { try HerdrClient.result(from: Data(#"{"id":"1","error":{"code":"events_lost","message":""}}"#.utf8)) }

        let agents = try HerdrTransport.agents(fromCLIOutput: Data(#"{"id":"cli:agent:list","result":{"agents":[{"agent":"claude","agent_status":"working","cwd":"/repo","foreground_cwd":"/repo/sub","pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_title_stripped":"fix bug"}],"type":"agent_list"}}"#.utf8))
        #expect(agents.count == 1 && agents[0].currentDirectory == "/repo/sub")
        let target = try #require(HerdrTransport.target(for: agents[0], hostID: .local, hostLabel: nil))
        #expect(target.label == "claude · fix bug (w1:p1)" && target.status == "working")
        #expect(HerdrTransport.identity(from: target)?.paneID == "w1:p1")
        #expect(HerdrTransport.target(for: HerdrAgentInfo(paneID: "w1:p9"), hostID: .local, hostLabel: nil) == nil, "panes without an agent are not targets")

        let event = try HerdrClient.event(from: Data(#"{"event":"pane_focused","data":{"type":"pane_focused","pane_id":"w1:p2","workspace_id":"w1"}}"#.utf8))
        #expect(event == HerdrEvent(event: "pane_focused", paneID: "w1:p2", workspaceID: "w1"))
        #expect(HerdrTransport.map(.server(code: "agent_blocked", message: "")) == .agentBlocked("The agent is waiting on a permission prompt"))
    }

    @Test(.enabled(if: TestGates.herdr))
    func pingsListsAndSubscribesOnTheLiveServer() async throws {
        let client = HerdrClient(socketPath: HerdrEndpoint.localSocketPath())
        let pong = try await client.ping()
        #expect(pong.protocol == 22)
        _ = try await client.agentList()

        let stream = client.subscribe([["type": "pane.focused"]])
        let acked = Task { () -> Bool in
            // The ack is consumed inside subscribe; a stream that stays open for a moment without throwing means it was accepted.
            do {
                for try await _ in stream { return true }
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        acked.cancel()
        #expect(await acked.value, "subscription stays open until cancelled")
    }

    /// Creates a pane running a stand-in binary named `claude` (Herdr detects agents by the foreground process
    /// name), prompts it, reads the text back, and closes the pane on every path.
    @Test(.enabled(if: TestGates.herdr))
    func promptsAPaneItCreatedAndClosesIt() async throws {
        let standIn = try Self.buildStandInAgent()
        defer { try? FileManager.default.removeItem(atPath: (standIn as NSString).deletingLastPathComponent) }
        let client = HerdrClient(socketPath: HerdrEndpoint.localSocketPath())
        let agents = try await client.agentList()
        var params: [String: any Sendable] = ["direction": "down", "cwd": "/tmp", "ratio": 0.2]
        if let workspace = agents.first?.workspaceID { params["workspace_id"] = workspace }
        let split = try await client.call("pane.split", params: params)
        let paneID = try #require((split["pane"] as? [String: Any])?["pane_id"] as? String)
        do {
            try await Task.sleep(for: .seconds(1))   // let the shell finish starting before typing into it
            _ = try await client.call("pane.send_text", params: ["pane_id": paneID, "text": "exec \(standIn)\n"])
            // Herdr notices a new agent on its own schedule, slower when the machine is busy (a parallel build):
            // up to 15 s rather than a guess at how long it takes.
            var detected = false
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(250))
                if let pane = try? await client.paneGet(paneID), pane.agent == "claude" { detected = true; break }
            }
            #expect(detected, "Herdr detects the stand-in as a claude pane")
            let marker = "gloss-herdr-\(UUID().uuidString.prefix(6))"
            let prompted = try await client.prompt(target: paneID, text: "line one \(marker)\nline two \(marker)")
            #expect(prompted?.paneID == paneID)
            var text = ""
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(200))
                text = try await client.paneRead(paneID, source: "visible", lines: 40)
                if text.contains("line two \(marker)") { break }
            }
            #expect(text.contains("line one \(marker)") && text.contains("line two \(marker)"), "the whole packet arrived in one paste: \(text)")
        } catch {
            _ = try? await client.call("pane.close", params: ["pane_id": paneID])
            throw error
        }
        let closed = try await client.call("pane.close", params: ["pane_id": paneID])
        #expect(closed["type"] as? String == "ok")
    }

    /// A tiny echo program compiled as `<tmp>/claude`; copying /bin/cat would be refused by the platform binary check.
    static func buildStandInAgent() throws -> String {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-herdr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let source = "#include <stdio.h>\nint main(void){int c;while((c=getchar())!=EOF){putchar(c);fflush(stdout);}return 0;}\n"
        try source.write(toFile: "\(directory)/claude.c", atomically: true, encoding: .utf8)
        let result = TestGates.run("/usr/bin/cc", ["-o", "\(directory)/claude", "\(directory)/claude.c"])
        guard result.status == 0 else { throw HerdrError.connection("cc failed") }
        return "\(directory)/claude"
    }
}
