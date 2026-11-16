import Core
import Foundation
import Synchronization
import Testing
@testable import Transports

/// herdr-core: listing agents here and on its machines, typing a packet, and reading its event stream. A stand-in
/// socket answers as the core does (replies captured from herdr-core 0.1.21, identifiers made up).
struct HerdrCoreTests {
    /// A Unix socket speaking line-delimited JSON-RPC: each request gets `answer(method, params)` (a result, or an
    /// `{"error":…}` object passed through), then `after(method)` lines, and the connection stays open.
    final class FakeCore: @unchecked Sendable {
        let path: String
        private let fd: Int32
        final class Recorder: Sendable {
            let requests = Mutex<[Data]>([])
        }
        let recorder = Recorder()
        var lastRequest: [String: Any]? {
            recorder.requests.withLock { $0.last }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        init(answer: @escaping @Sendable (String, [String: Any]) -> Any, after: @escaping @Sendable (String) -> [String] = { _ in [] }) throws {
            let socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-hc-\(UUID().uuidString.prefix(6)).sock")
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) } }
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0, listen(listener, 8) == 0 else { close(listener); throw POSIXError(.EADDRINUSE) }
            path = socketPath
            fd = listener
            let recorder = recorder
            Thread {
                while true {
                    let client = accept(listener, nil, nil)
                    if client < 0 { break }
                    // A client that hung up must not end the test process with SIGPIPE.
                    var on: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    Thread {
                        var buffer = Data()
                        var chunk = [UInt8](repeating: 0, count: 65536)
                        while true {
                            let count = recv(client, &chunk, chunk.count, 0)
                            if count <= 0 { break }
                            buffer.append(contentsOf: chunk[0..<count])
                            while let newline = buffer.firstIndex(of: 0x0A) {
                                let line = buffer.subdata(in: buffer.startIndex..<newline)
                                buffer.removeSubrange(buffer.startIndex...newline)
                                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let method = request["method"] as? String else { continue }
                                recorder.requests.withLock { $0.append(line) }
                                let answer = answer(method, request["params"] as? [String: Any] ?? [:])
                                var reply: [String: Any] = ["jsonrpc": "2.0", "id": request["id"] ?? NSNull()]
                                if let error = (answer as? [String: Any])?["error"] { reply["error"] = error } else { reply["result"] = answer }
                                var lines = [String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self)]
                                lines += after(method)
                                let text = Data(lines.map { $0 + "\n" }.joined().utf8)
                                _ = text.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                            }
                        }
                        close(client)
                    }.start()
                }
            }.start()
        }

        func stop() {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
    }

    static let studio = HostID(rawValue: "h_01JSTD00000000000000000000")

    /// `terminal.list` as the core answers it: a shell, Claude Code here, Codex and a server on `studio`, Claude Code
    /// on a machine Gloss has no host for, and a finished agent.
    static var list: [String: Any] { [
        "hidden_finished": 0,
        "machines": [
            ["name": "studio", "target": "studio", "state": "connected", "version": "0.1.17"],
            ["name": "lab", "target": "lab.example", "state": "connected"],
            ["name": "den", "target": "den", "state": "needs_login"],
        ],
        "terminals": [
            ["address": "t4", "state": "live", "cwd": "/Users/u/Documents", "status": NSNull(), "foreground": ["name": "zsh", "argv": ["/bin/zsh", "-l"], "cwd": "/Users/u/Documents"], "title": "u@host:~/Documents", "labels": ["where": "Config / 1"]],
            ["address": "t7", "state": "live", "cwd": "/Users/u/Code/app", "status": ["app": "claude-code", "state": "working", "msg": "Reading"], "foreground": ["name": "2.1.325", "argv": ["claude", "--resume"], "cwd": "/Users/u/Code/app/Sources"], "title": "tidy-up", "labels": ["where": "App / 1"]],
            ["address": "studio/t3", "state": "live", "cwd": "/home/u/union", "status": NSNull(), "foreground": ["name": "codex", "argv": ["/home/u/.local/bin/codex"], "cwd": "/home/u/union"], "title": ""],
            ["address": "studio/t8", "state": "live", "cwd": "/home/u/serve", "name": "atlas", "status": NSNull(), "foreground": ["name": "python3", "argv": ["python3", "-m", "http.server"], "cwd": "/home/u/serve"]],
            ["address": "lab/t1", "state": "live", "cwd": "/srv", "status": ["app": "claude-code", "state": "idle"]],
            ["address": "t9", "state": "finished", "cwd": "/Users/u", "status": ["app": "claude-code", "state": "done"]],
        ],
    ] }

    func transport(_ core: FakeCore) -> HerdrCoreTransport {
        HerdrCoreTransport(client: HerdrCoreClient(socketPath: core.path)) { machine in machine.target == "studio" ? Self.studio : nil }
    }

    @Test func agentsAreListedHereAndOnTheMachinesTheCoreReaches() async throws {
        let core = try FakeCore { _, _ in Self.list }
        defer { core.stop() }
        let transport = transport(core)
        let discovery = await transport.discover(within: .seconds(5))
        let targets = discovery.targets.sorted { $0.label < $1.label }
        // The shell, the server, the finished agent, and the machine Gloss doesn't know are left out.
        #expect(targets.map(\.label) == ["claude-code · App / 1 · tidy-up (t7)", "studio: codex · union (studio/t3)"])
        let claude = try #require(targets.first)
        #expect(claude.hostID == .local && claude.status == "working" && claude.detail == "/Users/u/Code/app/Sources")
        let codex = try #require(targets.last)
        #expect(codex.hostID == Self.studio && codex.status == nil)
        // This Mac and the connected machine Gloss knows answered; `den` (needs login) keeps what it listed before.
        #expect(discovery.answered == [.local, Self.studio])
        #expect(await transport.machines.map(\.name) == ["studio", "lab", "den"])
    }

    @Test func anAgentKeepsItsIdentityAsItsTitleAndStatusChange() async throws {
        var terminal = HCTerminal(address: "t7", status: HCStatus(state: "working", app: "claude-code"), cwd: "/a", title: "one")
        let before = try #require(HerdrCoreTransport.target(for: terminal, hostID: .local))
        terminal.title = "two"
        terminal.status?.state = "idle"
        let after = try #require(HerdrCoreTransport.target(for: terminal, hostID: .local))
        #expect(before.id == after.id && before.label != after.label)
        #expect(before.id == "herdr-core:h_local:t7 claude-code")
    }

    @Test func anAgentIsTheSameBeforeAndAfterItReportsItsStatus() throws {
        let quiet = HCTerminal(address: "t7", foreground: HCForeground(name: "2.1.325", argv: ["claude", "--resume"]))
        let reporting = HCTerminal(address: "t7", status: HCStatus(state: "idle", app: "claude-code"), foreground: quiet.foreground)
        #expect(try #require(HerdrCoreTransport.target(for: quiet, hostID: .local)).id == HerdrCoreTransport.target(for: reporting, hostID: .local)?.id)
    }

    @Test func aMachineThatLeavesTheCoreTakesItsAgents() async throws {
        let machines = Mutex(true)
        let core = try FakeCore { _, _ in
            var list = Self.list
            if !machines.withLock({ $0 }) {
                list["machines"] = [] as [Any]
                list["terminals"] = (list["terminals"] as! [[String: Any]]).filter { !(($0["address"] as? String) ?? "").contains("/") }
            }
            return list
        }
        defer { core.stop() }
        let transport = transport(core)
        #expect(await transport.discover(within: .seconds(5)).answered == [.local, Self.studio])
        machines.withLock { $0 = false }
        // `studio` is gone from the core: it answers for that host too, so its agents drop.
        #expect(await transport.discover(within: .seconds(5)).answered == [.local, Self.studio])
    }

    @Test func anErrorWithoutAnIDAnswersTheCall() async throws {
        let core = try FakeCore { _, _ in [:] as [String: Any] }
        defer { core.stop() }
        let line = Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error","data":{"kind":"parse"}}}"#.utf8)
        #expect(throws: HerdrCoreError.server(kind: "parse", message: "parse error")) { _ = try HerdrCoreClient.reply(from: line, id: 5) }
        let notification = Data(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":1}}"#.utf8)
        #expect(try HerdrCoreClient.reply(from: notification, id: 5) == nil)
    }

    @Test func aPacketIsTypedAsItIs() async throws {
        let core = try FakeCore { method, _ in method == "terminal.send" ? ["turn": 8, "status": "working", "started": true] as [String: Any] : [:] }
        defer { core.stop() }
        let transport = transport(core)
        let target = try #require(HerdrCoreTransport.target(for: HCTerminal(address: "studio/t3", foreground: HCForeground(name: "codex")), hostID: Self.studio))
        let receipt = try await transport.deliver(Packet(text: "# Notes\nline two", noteIDs: []), attachments: [], to: target)
        #expect(receipt.detail == "typed into studio/t3")
        let sent = try #require(core.lastRequest)
        #expect(sent["method"] as? String == "terminal.send")
        let params = try #require(sent["params"] as? [String: Any])
        #expect(params["terminal"] as? String == "studio/t3" && params["text"] as? String == "# Notes\nline two")
        // No caller: the core would otherwise wrap the text in an <hc> tag from that terminal.
        #expect(params["caller"] == nil)
    }

    @Test func theCoreRefusalsReadAsDeliveryErrors() async throws {
        @Sendable func error(_ kind: String, _ message: String) -> [String: Any] {
            ["error": ["code": -32000, "message": message, "data": ["kind": kind, "hint": "see `hc ls --all`"]]]
        }
        let core = try FakeCore { _, params in
            switch params["terminal"] as? String {
            case "t1": error("blocked", "t1 is waiting on a permission prompt")
            case "t2": error("not_found", "no terminal \"t2\"")
            default: error("io", "broken pipe")
            }
        }
        defer { core.stop() }
        let transport = transport(core)
        func deliver(_ address: String) async -> DeliveryError? {
            let target = HerdrCoreTransport.target(for: HCTerminal(address: address, status: HCStatus(state: "idle", app: "codex")), hostID: .local)!
            do { _ = try await transport.deliver(Packet(text: "x", noteIDs: []), attachments: [], to: target); return nil }
            catch { return error as? DeliveryError }
        }
        #expect(await deliver("t1") == .agentBlocked("The agent is waiting on a prompt of its own; answer it, then send again"))
        #expect(await deliver("t2") == .targetUnavailable("no terminal \"t2\" (see `hc ls --all`)"))
        #expect(await deliver("t3") == .failed("broken pipe (see `hc ls --all`)"))
    }

    @Test func eventsStreamAfterTheSnapshot() async throws {
        let status = #"{"jsonrpc":"2.0","method":"event","params":{"data":{"records":{},"reported":true,"status":{"app":"claude-code","msg":"Fetching","state":"working"}},"seq":424,"terminal":"office/t8","type":"status"}}"#
        let lines = [
            #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":424}}"#,
            status,
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{},"seq":425,"terminal":"t2","type":"title"}}"#,
            #"{"jsonrpc":"2.0","method":"event","params":{"data":{},"seq":426,"terminal":"t2","type":"removed"}}"#,
            #"{"jsonrpc":"2.0","method":"missed","params":{"seq":500}}"#,
        ]
        let core = try FakeCore(answer: { _, _ in ["seq": 423, "terminals": [], "channel": NSNull()] as [String: Any] }, after: { $0 == "events.subscribe" ? lines : [] })
        defer { core.stop() }
        var events: [HCEvent] = []
        for try await event in HerdrCoreClient(socketPath: core.path).subscribe() {
            events.append(event)
            if events.count == lines.count { break }
        }
        #expect(events == [
            .heartbeat,
            .changed(type: "status", address: "office/t8", status: HCStatus(state: "working", app: "claude-code", msg: "Fetching")),
            .changed(type: "title", address: "t2", status: nil),
            .lifecycle(type: "removed", address: "t2"),
            .missed,
        ])
    }

    @Test func noCoreMeansNoAgentsAndNoAnswer() async {
        let transport = HerdrCoreTransport(client: HerdrCoreClient(socketPath: "/nonexistent/hc.sock")) { _ in nil }
        let discovery = await transport.discover(within: .seconds(2))
        // No socket is a definite answer for every host: whatever herdr-core listed before is gone.
        #expect(discovery.targets.isEmpty && discovery.answered == nil)
    }

    @Test func theSocketFollowsTheSession() {
        let home = NSHomeDirectory()
        #expect(HerdrCoreEndpoint.socketPath(environment: [:]) == "\(home)/.local/state/herdr-core/default/default.sock")
        #expect(HerdrCoreEndpoint.socketPath(environment: ["HC_SESSION": "office", "XDG_STATE_HOME": "/tmp/s"]) == "/tmp/s/herdr-core/office/office.sock")
    }

    /// Against the real core, read-only: whatever it lists decodes and becomes targets.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: HerdrCoreEndpoint.socketPath())))
    func theLocalCoreListsWithoutErrors() async throws {
        let list = try await HerdrCoreClient().list()
        for terminal in list.terminals { _ = HerdrCoreTransport.target(for: terminal, hostID: .local) }
        #expect(Set(list.machines.map(\.name)).count == list.machines.count)
    }
}
