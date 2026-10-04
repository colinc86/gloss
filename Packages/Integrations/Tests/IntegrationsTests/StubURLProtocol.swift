import Foundation

/// Canned responses and a record of every request for one test's session; suites run in parallel, so each
/// session finds its own stub through a header the session adds.
final class Stub: @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()

        static func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"].merging(headers) { $1 }, body: Data(string.utf8))
        }
    }

    let id = UUID().uuidString
    private var responses: [String: Response] = [:]
    private var requests: [URLRequest] = []
    private let lock = NSLock()

    init() {
        StubURLProtocol.register(self)
    }

    func respond(to url: String, with response: Response) {
        lock.lock(); defer { lock.unlock() }
        responses[url] = response
    }

    var recorded: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    fileprivate func serve(_ request: URLRequest) -> Response? {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return responses[request.url!.absoluteString]
    }

    /// A session whose requests all come to this stub.
    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.header: id]
        return URLSession(configuration: configuration)
    }
}

final class StubURLProtocol: URLProtocol {
    static let header = "X-Gloss-Stub"
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    private static let lock = NSLock()

    static func register(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        stubs[stub.id] = stub
    }

    private static func stub(for request: URLRequest) -> Stub? {
        lock.lock(); defer { lock.unlock() }
        return request.value(forHTTPHeaderField: header).flatMap { stubs[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.stub(for: request), let response = stub.serve(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        // A cached read presents its ETag; the stub answers 304 when it matches, as the real servers do.
        if let tag = request.value(forHTTPHeaderField: "If-None-Match"), tag == response.headers["ETag"] {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
