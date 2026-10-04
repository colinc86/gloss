import Foundation
import MCP
@preconcurrency import NIOCore
import NIOHTTP1
import NIOPosix

/// A minimal HTTP/1.1 listener on the loopback interface that hands whole requests to a handler and writes plain
/// or streamed (SSE) responses. Mirrors the MCP SDK's conformance adapter; NIO is already in the SDK's graph.
public final class HTTPListener: Sendable {
    public typealias Handler = @Sendable (HTTPRequest, _ query: [String: String]) async -> HTTPResponse

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    public let port: Int

    private init(group: MultiThreadedEventLoopGroup, channel: Channel, port: Int) {
        self.group = group
        self.channel = channel
        self.port = port
    }

    /// Binds 127.0.0.1:`port` (0 picks a free port) and serves until `stop()`.
    public static func start(port: Int, handler: @escaping Handler) async throws -> HTTPListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(RequestHandler(handler: handler))
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
    private var pending: Pending?
    private var streamTask: Task<Void, Never>?
    /// The port is reverse-forwarded to hosts, so anything on their loopback can POST; bound what we buffer.
    private static let maximumBodyBytes = 8 * 1024 * 1024

    init(handler: @escaping HTTPListener.Handler) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pending = Pending(head: head, body: context.channel.allocator.buffer(capacity: 0))
        case .body(var buffer):
            guard pending != nil else { return }
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
            guard let request = pending else { return }
            pending = nil
            nonisolated(unsafe) let ctx = context
            let handler = handler
            streamTask = Task {
                let (mcpRequest, query) = Self.convert(request)
                let response = await handler(mcpRequest, query)
                await Self.write(response, version: request.head.version, keepAlive: request.head.isKeepAlive, context: ctx, wrap: { self.wrapOutboundOut($0) })
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

    private static func write(_ response: HTTPResponse, version: HTTPVersion, keepAlive: Bool, context: ChannelHandlerContext, wrap: @escaping @Sendable (HTTPServerResponsePart) -> NIOAny) async {
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
                ctx.writeAndFlush(wrap(.end(nil))).whenComplete { _ in if !keepAlive { ctx.close(promise: nil) } }
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
                ctx.writeAndFlush(wrap(.end(nil))).whenComplete { _ in if !keepAlive { ctx.close(promise: nil) } }
            }
        }
    }
}
