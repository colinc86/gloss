import Foundation
import Network
import Synchronization

/// Newline-delimited JSON over Herdr's Unix socket. Stateless, so any task may use one value concurrently. One request per connection (the server closes after replying)
/// except `events.subscribe`, which stays open and streams frames.
public struct HerdrClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: Raw calls

    /// Sends one request and returns the `result` object of the first reply line.
    public func call(_ method: String, params: [String: any Sendable] = [:]) async throws -> [String: Any] {
        let line = try Self.requestLine(method: method, params: params)
        let connection = LineConnection(socketPath: socketPath)
        defer { connection.cancel() }
        try await connection.open()
        try await connection.send(line)
        guard let first = try await connection.nextLine() else { throw HerdrError.emptyReply }
        return try Self.result(from: first)
    }

    static func requestLine(method: String, params: [String: any Sendable]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params])
        data.append(0x0A)
        guard data.count <= HerdrError.lineLimit else { throw HerdrError.requestTooLarge(data.count) }
        return data
    }

    static func result(from line: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw HerdrError.decoding("not a JSON object") }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "error"
            if code == "events_lost" { throw HerdrError.eventsLost }
            throw HerdrError.server(code: code, message: error["message"] as? String ?? "")
        }
        guard let result = object["result"] as? [String: Any] else { throw HerdrError.decoding("reply has neither result nor error") }
        return result
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HerdrError.decoding("\(T.self): \(error)")
        }
    }

    // MARK: Typed methods

    public func ping() async throws -> HerdrPong {
        try Self.decode(HerdrPong.self, from: try await call("ping"))
    }

    public func agentList() async throws -> [HerdrAgentInfo] {
        let result = try await call("agent.list")
        return try Self.decode([HerdrAgentInfo].self, from: result["agents"] ?? [])
    }

    public func paneGet(_ paneID: String) async throws -> HerdrAgentInfo {
        let result = try await call("pane.get", params: ["pane_id": paneID])
        return try Self.decode(HerdrAgentInfo.self, from: result["pane"] ?? [:])
    }

    /// `agent.prompt` with `wait: null`: bracketed paste plus Enter, returns as soon as Herdr accepted the text.
    public func prompt(target: String, text: String) async throws -> HerdrAgentInfo? {
        let result = try await call("agent.prompt", params: ["target": target, "text": text, "wait": NSNull()])
        return (result["agent"]).flatMap { try? Self.decode(HerdrAgentInfo.self, from: $0) }
    }

    public func paneRead(_ paneID: String, source: String = "visible", lines: Int = 80) async throws -> String {
        let result = try await call("pane.read", params: ["pane_id": paneID, "source": source, "lines": lines, "format": "text"])
        return ((result["read"] as? [String: Any])?["text"] as? String) ?? ""
    }

    // MARK: Events

    /// Opens a subscription and streams its frames until the server closes the connection or the consumer cancels.
    /// Throws `HerdrError.eventsLost` when the server reports it fell behind.
    public func subscribe(_ subscriptions: [[String: String]]) -> AsyncThrowingStream<HerdrEvent, any Error> {
        let socketPath = socketPath
        return AsyncThrowingStream { continuation in
            let connection = LineConnection(socketPath: socketPath)
            let task = Task {
                do {
                    try await connection.open()
                    try await connection.send(try Self.requestLine(method: "events.subscribe", params: ["subscriptions": subscriptions]))
                    guard let ack = try await connection.nextLine() else { throw HerdrError.emptyReply }
                    let acked = try Self.result(from: ack)
                    guard acked["type"] as? String == "subscription_started" else { throw HerdrError.subscriptionRefused("\(acked)") }
                    while let line = try await connection.nextLine() {
                        if let event = try Self.event(from: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                connection.cancel()
            }
        }
    }

    static func event(from line: Data) throws -> HerdrEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if object["error"] != nil { _ = try result(from: line) }
        guard let name = object["event"] as? String else { return nil }
        let data = object["data"] as? [String: Any] ?? [:]
        let pane = data["pane"] as? [String: Any]
        return HerdrEvent(
            event: name,
            paneID: data["pane_id"] as? String ?? pane?["pane_id"] as? String,
            workspaceID: data["workspace_id"] as? String ?? pane?["workspace_id"] as? String,
            agent: data["agent"] as? String ?? pane?["agent"] as? String,
            agentStatus: data["agent_status"] as? String ?? data["status"] as? String ?? pane?["agent_status"] as? String
        )
    }
}

/// An `NWConnection` to a Unix socket that hands back newline-delimited lines. Callbacks run on a private queue and
/// touch only the mutex-guarded buffer and the waiting continuation.
final class LineConnection: Sendable {
    private struct State {
        var buffer = Data()
        var finished = false
        var failure: (any Error)?
        var waiter: CheckedContinuation<Data?, any Error>?
        var opened: CheckedContinuation<Void, any Error>?
        var openResolved = false
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.cnc.Gloss.herdr")
    private let state = Mutex(State())

    init(socketPath: String) {
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            state.withLock { $0.opened = continuation }
            connection.stateUpdateHandler = { [self] newState in
                switch newState {
                case .ready:
                    resolveOpen(nil)
                    receive()
                case .failed(let error):
                    resolveOpen(HerdrError.connection("\(error)"))
                    finish(error: HerdrError.connection("\(error)"))
                case .cancelled:
                    resolveOpen(HerdrError.connection("cancelled"))
                    finish(error: nil)
                case .waiting(let error):
                    // A missing socket surfaces as waiting(POSIX ENOENT) and never fails; treat it as a failure.
                    resolveOpen(HerdrError.connection("\(error)"))
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func resolveOpen(_ error: (any Error)?) {
        let waiter: CheckedContinuation<Void, any Error>? = state.withLock { state in
            guard !state.openResolved else { return nil }
            state.openResolved = true
            defer { state.opened = nil }
            return state.opened
        }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: HerdrError.connection("\(error)")) } else { continuation.resume() }
            })
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] content, _, isComplete, error in
            if let content, !content.isEmpty {
                let oversized = state.withLock { state -> Bool in
                    state.buffer.append(content)
                    // Only the unterminated tail counts; complete lines waiting for a slow consumer are fine.
                    let tailStart = state.buffer.lastIndex(of: 0x0A).map { $0 + 1 } ?? state.buffer.startIndex
                    return state.buffer.endIndex - tailStart > HerdrError.lineLimit
                }
                if oversized {
                    finish(error: HerdrError.decoding("reply line over 1 MiB"))
                    connection.cancel()
                    return
                }
                deliverLines()
            }
            if let error {
                finish(error: HerdrError.connection("\(error)"))
            } else if isComplete {
                finish(error: nil)
            } else {
                receive()
            }
        }
    }

    /// Resumes the waiting reader with the next complete line, if any.
    private func deliverLines() {
        let delivery: (CheckedContinuation<Data?, any Error>, Data)? = state.withLock { state in
            guard let waiter = state.waiter, let newline = state.buffer.firstIndex(of: 0x0A) else { return nil }
            let line = state.buffer.subdata(in: state.buffer.startIndex..<newline)
            state.buffer.removeSubrange(state.buffer.startIndex...newline)
            state.waiter = nil
            return (waiter, line)
        }
        if let (waiter, line) = delivery { waiter.resume(returning: line) }
    }

    private func finish(error: (any Error)?) {
        let waiter: (CheckedContinuation<Data?, any Error>, Data?)? = state.withLock { state in
            state.finished = true
            state.failure = state.failure ?? error
            guard let waiter = state.waiter else { return nil }
            state.waiter = nil
            // A final line without a trailing newline still counts.
            let rest = state.buffer
            state.buffer = Data()
            return (waiter, rest.isEmpty ? nil : rest)
        }
        guard let (continuation, rest) = waiter else { return }
        if let rest { continuation.resume(returning: rest) } else if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
    }

    /// The next line, or nil at EOF. Throws when the connection failed.
    func nextLine() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            let immediate: Result<Data?, any Error>? = state.withLock { state in
                if let newline = state.buffer.firstIndex(of: 0x0A) {
                    let line = state.buffer.subdata(in: state.buffer.startIndex..<newline)
                    state.buffer.removeSubrange(state.buffer.startIndex...newline)
                    return .success(line)
                }
                if state.finished {
                    if let failure = state.failure { return .failure(failure) }
                    let rest = state.buffer
                    state.buffer = Data()
                    return .success(rest.isEmpty ? nil : rest)
                }
                state.waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    func cancel() {
        connection.cancel()
    }
}
