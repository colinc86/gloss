import Foundation
import Testing
@testable import Remote

struct StreamingTests {
    /// Both pipes must deliver each chunk as the child writes it, not only at exit.
    @Test func stderrChunksArriveAsTheyAreWritten() async throws {
        let process = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sh", arguments: ["-c", "echo one >&2; sleep 0.4; echo two >&2; sleep 0.4; echo three >&2"]))
        let start = ContinuousClock.now
        var arrivals: [(String, Duration)] = []
        for await chunk in process.stderr {
            arrivals.append((String(decoding: chunk, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), ContinuousClock.now - start))
        }
        _ = try await process.exitCode
        #expect(arrivals.map(\.0) == ["one", "two", "three"], "\(arrivals)")
        #expect(arrivals.count == 3 && arrivals[1].1 > .milliseconds(300) && arrivals[2].1 > .milliseconds(700), "chunks arrive as written, not batched at exit: \(arrivals)")
    }
}

