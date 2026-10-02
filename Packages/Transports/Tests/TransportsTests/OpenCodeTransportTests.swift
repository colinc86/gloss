import Core
import Foundation
import MCP
import Testing
@testable import Transports

struct OpenCodeTransportTests {
    @Test func parsesServerListsAndBuildsBodies() {
        let servers = OpenCodeServer.parse("http://127.0.0.1:4096, user:secret@box.local:4097 ,, https://x.example/")
        #expect(servers.map(\.baseURL.absoluteString) == ["http://127.0.0.1:4096", "http://box.local:4097", "https://x.example"])
        #expect(servers[1].username == "user" && servers[1].password == "secret" && servers[1].authorizationHeader == "Basic " + Data("user:secret".utf8).base64EncodedString())
        #expect(servers[0].authorizationHeader == nil)
        let packet = PacketBuilder.build([PacketNote(noteID: NoteID.new(), agentPath: "/tmp/a.md", source: .markdown, anchor: .wholeFile, comment: "c")])
        let body = OpenCodeTransport.promptBody(packet: packet, attachments: [StagedAttachment(noteID: NoteID.new(), agentPath: "/tmp/crop one.png")])
        let parts = body["parts"] as? [[String: Any]] ?? []
        #expect(parts.count == 2 && parts[0]["type"] as? String == "text" && parts[0]["text"] as? String == packet.text)
        #expect(parts[1]["type"] as? String == "file" && parts[1]["mime"] as? String == "image/png" && parts[1]["url"] as? String == "file:///tmp/crop%20one.png" && parts[1]["filename"] as? String == "crop one.png")
    }

    /// A fake OpenCode server on our own listener: sessions are listed, prompts land on prompt_async with auth, and a
    /// "new session" target creates one first.
    @Test func deliversToAFakeOpenCodeServer() async throws {
        let log = RequestLog()
        let listener = try await HTTPListener.start(port: 0) { request, _ in
            await log.record(request)
            // Messages: every recorded prompt is echoed back as a user message, as OpenCode does.
            if request.method == "GET", request.path?.hasSuffix("/message") == true {
                let prompts = await log.requests.filter { $0.method == "POST" && $0.path?.hasSuffix("/prompt_async") == true }
                let messages: [[String: Any]] = prompts.compactMap { prompt in
                    guard let body = prompt.body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
                    return ["info": ["id": "msg", "role": "user"], "parts": object["parts"] ?? []]
                }
                return .data(try! JSONSerialization.data(withJSONObject: messages), headers: ["Content-Type": "application/json"])
            }
            switch (request.method, request.path ?? "") {
            case ("GET", "/session"):
                let json = try! JSONSerialization.data(withJSONObject: [["id": "ses_1", "title": "Fix tests", "directory": "/repo"], ["id": "ses_2", "title": "", "directory": "/other"]])
                return .data(json, headers: ["Content-Type": "application/json"])
            case ("POST", "/session"):
                return .data(try! JSONSerialization.data(withJSONObject: ["id": "ses_new"]), headers: ["Content-Type": "application/json"])
            case ("POST", "/session/ses_1/prompt_async"), ("POST", "/session/ses_new/prompt_async"):
                return .ok(headers: [:])
            default:
                return .error(statusCode: 404, MCPError.methodNotFound("nope"))
            }
        }
        defer { Task { await listener.stop() } }
        let server = OpenCodeServer(baseURL: URL(string: "http://127.0.0.1:\(listener.port)")!, username: "opencode", password: "pw")
        let transport = OpenCodeTransport(servers: { [server] })
        let targets = try await transport.discoverTargets()
        #expect(targets.map(\.label) == ["Fix tests · 127.0.0.1", "untitled · 127.0.0.1", "New session · 127.0.0.1"])
        #expect(targets[0].detail == "/repo")

        let packet = PacketBuilder.build([PacketNote(noteID: NoteID.new(), agentPath: "/tmp/a.md", source: .markdown, anchor: .wholeFile, comment: "hello")])
        let receipt = try await transport.deliver(packet, attachments: [], to: targets[0])
        #expect(receipt.detail == "session ses_1")
        let prompt = try #require(await log.requests.last { $0.method == "POST" })
        #expect(prompt.path == "/session/ses_1/prompt_async" && prompt.header("Authorization") == "Basic " + Data("opencode:pw".utf8).base64EncodedString())
        let sent = try JSONSerialization.jsonObject(with: try #require(prompt.body)) as? [String: Any]
        #expect(((sent?["parts"] as? [[String: Any]])?.first?["text"] as? String) == packet.text)

        let fresh = try await transport.deliver(packet, attachments: [], to: targets[2])
        #expect(fresh.detail == "new session ses_new")
        #expect(await log.requests.filter { $0.method == "POST" }.map { $0.path ?? "" }.suffix(2) == ["/session", "/session/ses_new/prompt_async"])
        #expect(await log.requests.last?.path == "/session/ses_new/message", "delivery is confirmed by reading the messages back")

        let dead = OpenCodeTransport(servers: { [OpenCodeServer(baseURL: URL(string: "http://127.0.0.1:1")!)] })
        #expect(try await dead.discoverTargets().isEmpty)
        await listener.stop()
    }
}

actor RequestLog {
    private(set) var requests: [HTTPRequest] = []
    func record(_ request: HTTPRequest) { requests.append(request) }
}
