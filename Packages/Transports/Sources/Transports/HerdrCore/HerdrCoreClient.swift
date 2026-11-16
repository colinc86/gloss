import Foundation
import Synchronization

/// JSON-RPC 2.0, one message per line, on herdr-core's Unix socket. Stateless: each call opens its own connection,
/// so any task may use one value concurrently. `subscribe` keeps its connection open and streams notifications.
public struct HerdrCoreClient: Sendable {
    public let socketPath: String

    public init(socketPath: String = HerdrCoreEndpoint.socketPath()) {
        self.socketPath = socketPath
    }

    public static let callTimeout: Duration = .seconds(15)
    /// A send waits out a person's half-typed draft (at most 60 s since their last key), so it gets longer.
    public static let sendTimeout: Duration = .seconds(75)

    /// Sends one request and returns the `result` of its reply, skipping any notification that arrives first.
    public func call(_ method: String, params: [String: any Sendable] = [:], timeout: Duration = HerdrCoreClient.callTimeout) async throws -> Any {
        let id = Int.random(in: 1...Int(Int32.max))
        let line = try Self.requestLine(id: id, method: method, params: params)
        let connection = LineConnection(socketPath: socketPath)
        defer { connection.cancel() }
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            connection.fail(HerdrError.timedOut)
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await connection.open()
            try await connection.send(line)
            while let reply = try await connection.nextLine() {
                if let result = try Self.reply(from: reply, id: id) { return result }
            }
            throw HerdrCoreError.emptyReply
        } onCancel: {
            connection.fail(CancellationError())
        }
    }

    static func requestLine(id: Int, method: String, params: [String: any Sendable]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        data.append(0x0A)
        guard data.count <= HerdrError.lineLimit else { throw HerdrError.requestTooLarge(data.count) }
        return data
    }

    /// The result of the reply to `id`; nil for any other line (a notification). Throws the reply's error.
    static func reply(from line: Data, id: Int) throws -> Any? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw HerdrCoreError.decoding("not a JSON object") }
        // Each connection carries one request, so an error with no id (a line the core couldn't read) is its answer.
        let unaddressedError = object["error"] != nil && (object["id"] == nil || object["id"] is NSNull)
        guard (object["id"] as? Int) == id || unaddressedError else { return nil }
        if let error = object["error"] as? [String: Any] {
            let kind = (error["data"] as? [String: Any])?["kind"] as? String ?? "error"
            var message = error["message"] as? String ?? ""
            if let hint = (error["data"] as? [String: Any])?["hint"] as? String, !hint.isEmpty { message += message.isEmpty ? hint : " (\(hint))" }
            throw HerdrCoreError.server(kind: kind, message: message)
        }
        guard let result = object["result"] else { throw HerdrCoreError.decoding("reply has neither result nor error") }
        return result
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HerdrCoreError.decoding("\(T.self): \(error)")
        }
    }

    // MARK: Typed methods

    /// Every live terminal here and on every machine the core reaches, and those machines.
    public func list() async throws -> HCList {
        let result = try await call("terminal.list") as? [String: Any] ?? [:]
        return HCList(
            terminals: try Self.decode([HCTerminal].self, from: result["terminals"] ?? []),
            machines: try Self.decode([HCMachine].self, from: result["machines"] ?? [])
        )
    }

    public func get(_ address: String) async throws -> HCTerminal {
        try Self.decode(HCTerminal.self, from: try await call("terminal.get", params: ["terminal": address]))
    }

    /// Pastes `text` and presses Enter. No `caller`, so the core types it as it is (no `<hc>` tag).
    @discardableResult
    public func send(_ address: String, text: String) async throws -> String? {
        let result = try await call("terminal.send", params: ["terminal": address, "text": text], timeout: Self.sendTimeout) as? [String: Any]
        return result?["status"] as? String
    }

    public func version() async throws -> String? {
        (try await call("server.status") as? [String: Any])?["version"] as? String
    }

    // MARK: Events

    /// Subscribes to every terminal's changes and streams them until the core closes the connection or the consumer
    /// cancels. The snapshot that opens the subscription is not yielded (callers list on their own). A slow consumer
    /// keeps the newest 256 events; each is only a hint to look again.
    public func subscribe() -> AsyncThrowingStream<HCEvent, any Error> {
        let socketPath = socketPath
        return AsyncThrowingStream(HCEvent.self, bufferingPolicy: .bufferingNewest(256)) { continuation in
            let connection = LineConnection(socketPath: socketPath)
            let task = Task {
                do {
                    let acknowledged = Mutex(false)
                    let watchdog = Task {
                        try await Task.sleep(for: Self.callTimeout)
                        if !acknowledged.withLock({ $0 }) { connection.fail(HerdrError.timedOut) }
                    }
                    defer { watchdog.cancel() }
                    let id = 1
                    try await connection.open()
                    try await connection.send(try Self.requestLine(id: id, method: "events.subscribe", params: [:]))
                    while !acknowledged.withLock({ $0 }) {
                        guard let line = try await connection.nextLine() else { throw HerdrCoreError.emptyReply }
                        if try Self.reply(from: line, id: id) != nil { acknowledged.withLock { $0 = true } }
                    }
                    watchdog.cancel()
                    while let line = try await connection.nextLine() {
                        if let event = Self.event(from: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                connection.fail(CancellationError())
            }
        }
    }

    static func event(from line: Data) -> HCEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let method = object["method"] as? String else { return nil }
        switch method {
        case "heartbeat": return .heartbeat
        case "missed": return .missed
        case "event": break
        default: return nil
        }
        guard let params = object["params"] as? [String: Any], let type = params["type"] as? String else { return nil }
        let address = params["terminal"] as? String ?? ""
        switch type {
        case "created", "lost", "restarted", "finished", "removed":
            return .lifecycle(type: type, address: address)
        default:
            let data = params["data"] as? [String: Any]
            let status = (data?["status"]).flatMap { try? decode(HCStatus.self, from: $0) }
            return .changed(type: type, address: address, status: status)
        }
    }
}
