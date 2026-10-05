import Foundation
import MCP
import Synchronization
@preconcurrency import NIOCore
import NIOHTTP1
import NIOPosix

/// A minimal HTTP/1.1 listener on the loopback interface that hands whole requests to a handler and writes plain
/// or streamed (SSE) responses. Mirrors the MCP SDK's conformance adapter; NIO is already in the SDK's graph.
public final class HTTPListener: Sendable {
    /// Who may talk to the server: the agents, hooks and plugin, which call it by a loopback address and send no
    /// Origin. A browser always sends Origin on cross-site requests (and on same-origin ones after a DNS
    /// rebinding, whose Host is then the attacker's name), so either one names a web page and is refused, as the
    /// MCP specification asks of local servers.
    nonisolated static func permits(_ headers: HTTPHeaders) -> Bool {
        if !headers["Origin"].isEmpty { return false }
        guard let host = headers["Host"].first else { return true }
        let name: Substring
        if host.hasPrefix("[") {
            name = host.prefix { $0 != "]" }.dropFirst()
        } else {
            name = host.split(separator: ":").first ?? Substring(host)
        }
        return ["127.0.0.1", "localhost", "::1"].contains(name.lowercased())
    }

    public typealias Handler = @Sendable (HTTPRequest, _ query: [String: String]) async -> HTTPResponse
    /// Decides from the request line and headers alone (the body is nil) whether to read the request at all.
    public typealias Authorizer = @Sendable (HTTPRequest, _ query: [String: String]) -> Bool

    public struct Limits: Sendable {
        /// Connections held at once; past this new ones are closed on accept. Agents and hooks hold a handful.
        public var maximumConnections = 64
        /// How long a request may take to arrive: from connecting, from its first line, or after the previous
        /// response on a kept-alive connection, to its last byte.
        public var requestTimeout: TimeAmount = .seconds(30)
        public init() {}
    }

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    public let port: Int

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, port: Int) {
        self.group = group
        self.channel = channel
        self.port = port
    }

    /// Binds 127.0.0.1:`port` (0 picks a free port) and serves until `stop()`.
    public static func start(port: Int, authorize: Authorizer? = nil, limits: Limits = Limits(), handler: @escaping Handler) async throws -> HTTPListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let open = Atomic<Int>(0)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // The port is reverse-forwarded to remote hosts, where anyone logged in can open connections.
                guard open.add(1, ordering: .relaxed).newValue <= limits.maximumConnections else {
                    open.subtract(1, ordering: .relaxed)
                    return channel.close()
                }
                channel.closeFuture.whenComplete { _ in open.subtract(1, ordering: .relaxed) }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(RequestHandler(handler: handler, authorize: authorize, timeout: limits.requestTimeout))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        do {
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
            guard let bound = channel.localAddress?.port else { throw HTTPListenerError.bindFailed("no local address") }
            return HTTPListener(group: group, channel: channel, port: bound)
        } catch {
            try? await group.shutdownGracefully()
            throw HTTPListenerError.bindFailed("\(error)")
        }
    }

    public func stop() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }
}

public enum HTTPListenerError: Error, Sendable {
    case bindFailed(String)
}

/// Accumulates head, body, and end, then answers off the event loop; every write goes back through the loop.
private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct Pending {
        var head: HTTPRequestHead
        var body: ByteBuffer
    }

    private let handler: HTTPListener.Handler
    private let authorize: HTTPListener.Authorizer?
    private var pending: Pending?
    /// After a refusal on the head, the rest of that request is read and dropped.
    private var discarding = false
    private var streamTask: Task<Void, Never>?
    /// Closes a connection whose request doesn't arrive in time; cancelled once it has.
    private var deadline: Scheduled<Void>?
    /// Counts completed requests, so a finished response re-arms the deadline only if no later request (a
    /// pipelined one, which NIO hands over as soon as the previous `.end` is written) is already being served.
    private var served = 0
    private var isRemoved = false
    /// The port is reverse-forwarded to hosts, so anything on their loopback can POST; bound what we buffer.
    private static let maximumBodyBytes = 8 * 1024 * 1024

    private let timeout: TimeAmount

    init(handler: @escaping HTTPListener.Handler, authorize: HTTPListener.Authorizer?, timeout: TimeAmount) {
        self.handler = handler
        self.authorize = authorize
        self.timeout = timeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        armDeadline(context: context)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        isRemoved = true
        deadline?.cancel()
        deadline = nil
    }

    private func armDeadline(context: ChannelHandlerContext) {
        deadline?.cancel()
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        deadline = context.eventLoop.scheduleTask(in: timeout) { bound.value.close(promise: nil) }
    }

    /// Answers with an empty response and closes, without reading further.
    private func refuse(_ status: HTTPResponseStatus, context: ChannelHandlerContext) {
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: ["Content-Length": "0", "Connection": "close"])
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        // The completion runs on this channel's event loop; NIOLoopBound checks that rather than assuming it.
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in bound.value.close(promise: nil) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            armDeadline(context: context)
            // Refused before the body is buffered: a caller without the token can't make the server hold 8 MB.
            guard HTTPListener.permits(head.headers) else {
                discarding = true
                refuse(.forbidden, context: context)
                return
            }
            if let authorize {
                let probe = Self.convert(Pending(head: head, body: context.channel.allocator.buffer(capacity: 0)))
                guard authorize(probe.0, probe.1) else {
                    discarding = true
                    refuse(.unauthorized, context: context)
                    return
                }
            }
            discarding = false
            pending = Pending(head: head, body: context.channel.allocator.buffer(capacity: 0))
        case .body(var buffer):
            guard pending != nil, !discarding else { return }
            if (pending?.body.readableBytes ?? 0) + buffer.readableBytes > Self.maximumBodyBytes {
                pending = nil
                let head = HTTPResponseHead(version: .http1_1, status: .payloadTooLarge, headers: ["Content-Length": "0", "Connection": "close"])
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                // The completion runs on this channel's event loop; NIOLoopBound checks that rather than assuming it.
                let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in bound.value.close(promise: nil) }
                return
            }
            pending?.body.writeBuffer(&buffer)
        case .end:
            guard let request = pending, !discarding else { return }
            pending = nil
            deadline?.cancel()
            deadline = nil
            served += 1
            let generation = served
            guard HTTPListener.permits(request.head.headers) else {
                // A web page (any site open in a browser, or one rebinding its name to 127.0.0.1) must not reach the
                // notes: answered with 403 and the connection closed.
                let head = HTTPResponseHead(version: .http1_1, status: .forbidden, headers: ["Content-Length": "0", "Connection": "close"])
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in bound.value.close(promise: nil) }
                return
            }
            nonisolated(unsafe) let ctx = context
            let handler = handler
            streamTask = Task {
                let (mcpRequest, query) = Self.convert(request)
                let response = await handler(mcpRequest, query)
                // A kept-alive connection gets the same deadline for its next request, so idle ones don't hold slots.
                await Self.write(response, version: request.head.version, keepAlive: request.head.isKeepAlive, context: ctx, wrap: { self.wrapOutboundOut($0) }, finished: {
                    // On the event loop, after a successful write: only if this was the latest request and nothing new began.
                    if !self.isRemoved, self.served == generation, self.pending == nil { self.armDeadline(context: ctx) }
                })
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        streamTask?.cancel()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    private static func convert(_ request: Pending) -> (HTTPRequest, [String: String]) {
        var headers: [String: String] = [:]
        for (name, value) in request.head.headers {
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        let body: Data? = request.body.readableBytes > 0 ? Data(request.body.getBytes(at: 0, length: request.body.readableBytes) ?? []) : nil
        var components = URLComponents(string: request.head.uri)
        // curl --data-urlencode and HTML forms encode spaces as "+", which RFC 3986 query parsing keeps literal.
        if let query = components?.percentEncodedQuery { components?.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%20") }
        let path = components?.path ?? String(request.head.uri.split(separator: "?").first ?? Substring(request.head.uri))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return (HTTPRequest(method: request.head.method.rawValue, headers: headers, body: body, path: path), query)
    }

    /// `finished` runs on the event loop once a kept-alive response is fully written.
    private static func write(_ response: HTTPResponse, version: HTTPVersion, keepAlive: Bool, context: ChannelHandlerContext, wrap: @escaping @Sendable (HTTPServerResponsePart) -> NIOAny, finished: @escaping @Sendable () -> Void) async {
        nonisolated(unsafe) let ctx = context
        let loop = ctx.eventLoop
        var head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: response.statusCode))
        for (name, value) in response.headers { head.headers.add(name: name, value: value) }
        if !keepAlive { head.headers.replaceOrAdd(name: "Connection", value: "close") }
        let responseHead = head
        switch response {
        case .stream(let stream, _):
            loop.execute {
                ctx.write(wrap(.head(responseHead)), promise: nil)
                ctx.flush()
            }
            do {
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    loop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(wrap(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {}
            loop.execute {
                ctx.writeAndFlush(wrap(.end(nil))).whenComplete { result in
                    if !keepAlive { ctx.close(promise: nil) } else if case .success = result { finished() }
                }
            }
        default:
            let body = response.bodyData
            loop.execute {
                var head = responseHead
                if let body { head.headers.replaceOrAdd(name: "Content-Length", value: String(body.count)) } else if response.statusCode != 204 { head.headers.replaceOrAdd(name: "Content-Length", value: "0") }
                ctx.write(wrap(.head(head)), promise: nil)
                if let body {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(wrap(.body(.byteBuffer(buffer))), promise: nil)
                }
                ctx.writeAndFlush(wrap(.end(nil))).whenComplete { result in
                    if !keepAlive { ctx.close(promise: nil) } else if case .success = result { finished() }
                }
            }
        }
    }
}
