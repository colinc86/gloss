import Foundation
import Integrations
import Testing
@testable import Gloss

/// Every request goes to a stub: no test files a real issue.
struct IssueReporterTests {
    static let issues = "https://api.github.com/repos/colinc86/gloss/issues"

    /// URLProtocol sees a POST's body as a stream.
    func body(of request: URLRequest) throws -> [String: Any] {
        let stream = try #require(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { data.append(buffer, count: count) }
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func filesOnGlossOnlyWithTitleBodyAndLabel() async throws {
        let stub = Stub()
        stub.respond(to: Self.issues, with: .json(#"{"number":7,"html_url":"https://github.com/colinc86/gloss/issues/7"}"#, status: 201))
        let page = try await IssueReporter(token: "ghp_test", session: stub.session()).create(title: "Notes vanish", body: "Steps", kind: .feature)
        #expect(page.absoluteString == "https://github.com/colinc86/gloss/issues/7")
        let request = try #require(stub.recorded.first)
        #expect(stub.recorded.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == Self.issues)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_test")
        let sent = try body(of: request)
        #expect(sent["title"] as? String == "Notes vanish")
        #expect(sent["body"] as? String == "Steps")
        #expect(sent["labels"] as? [String] == ["enhancement"])
    }

    @Test func refusalsSendTheReaderToTheBrowserAndHiccupsDoNot() async throws {
        let cases: [(Stub.Response, Bool)] = [
            (.json(#"{"message":"Bad credentials"}"#, status: 401), true),
            (.json(#"{"message":"Resource not accessible by personal access token"}"#, status: 403), true),
            (.json(#"{"message":"Not Found"}"#, status: 404), true),
            (.json(#"{"message":"Issues are disabled for this repo"}"#, status: 410), true),
            (.json(#"{"message":"Validation Failed"}"#, status: 422), false),
            (.json(#"{"message":"API rate limit exceeded"}"#, status: 403, headers: ["X-RateLimit-Remaining": "0"]), false),
            (.json(#"{"message":"Server Error"}"#, status: 502), false),
        ]
        for (response, browser) in cases {
            let stub = Stub()
            stub.respond(to: Self.issues, with: response)
            do {
                _ = try await IssueReporter(token: "t", session: stub.session()).create(title: "x", body: "y", kind: .bug)
                Issue.record("status \(response.status) should throw")
            } catch {
                #expect(IssueReporter.needsBrowser(error) == browser, "status \(response.status)")
            }
        }
    }

    @Test func bodyCarriesTheTextTheVersionsIfAgreedAndTheMarker() {
        let info = "Gloss 0.1.0 (118) · macOS 26.0.0 · arm64"
        #expect(IssueReporter.body(kind: .bug, description: "  It broke.\n", systemInfo: info)
                == "It broke.\n\n---\n\(info)\n\n<!-- gloss-report: bug -->")
        #expect(IssueReporter.body(kind: .feature, description: " ", systemInfo: nil)
                == "_No description._\n\n<!-- gloss-report: feature -->")
    }

    @Test func systemInfoNamesOnlyTheAppTheOSAndTheChip() {
        let info = IssueReporter.systemInfo()
        #expect(info.hasPrefix("Gloss "))
        #expect(info.contains(" · macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)."))
        #expect(info.hasSuffix("arm64") || info.hasSuffix("x86_64"))
    }

    @Test func browserFormIsFilledInAndFitsTheLimit() throws {
        let url = IssueReporter.browserURL(title: "A + B & C", description: "Line one\nLine two", kind: .bug, systemInfo: "Gloss 0.1.0")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com")
        #expect(components.path == "/colinc86/gloss/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["title"] == "A + B & C")
        #expect(items["labels"] == "bug")
        #expect(items["body"]?.hasPrefix("Line one\nLine two") == true)

        let long = String(repeating: "ünïcode & words ", count: 2000)
        let trimmed = IssueReporter.browserURL(title: "Long", description: long, kind: .feature, systemInfo: "Gloss 0.1.0")
        #expect(trimmed.absoluteString.count <= 7000)
        let body = try #require(URLComponents(url: trimmed, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("…"))
        #expect(body.hasSuffix("<!-- gloss-report: feature -->"))
        #expect(body.contains("Gloss 0.1.0"))
    }
}
