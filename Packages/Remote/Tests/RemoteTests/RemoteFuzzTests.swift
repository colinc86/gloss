import Foundation
import Testing
@testable import Remote

/// A server can send anything: random replies (every type, truncated, padded, lying about their length) and random
/// text through the search, ssh config and listing parsers are refused or read, never a trap.
struct RemoteFuzzTests {
    @Test func garbageFromAServerNeverTraps() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            // A frame with a plausible length and a random body: every reply type, truncated or padded.
            let bodyLength = Int.random(in: 0...60, using: &rng)
            var body = Data((0..<bodyLength).map { _ in UInt8.random(in: 0...255, using: &rng) })
            if !body.isEmpty { body[0] = UInt8.random(in: 1...210, using: &rng) }
            var frame = Data()
            let declared = Bool.random(using: &rng) ? UInt32(body.count) : UInt32.random(in: 0...200, using: &rng)
            withUnsafeBytes(of: declared.bigEndian) { frame.append(contentsOf: $0) }
            frame.append(body)
            var buffer = frame
            while let _ = try? SFTPCodec.decode(from: &buffer), !buffer.isEmpty {}
            _ = try? SFTPCodec.decodePayload(body)
            var reader = BinaryReader(body)
            _ = try? reader.uint32(); _ = try? reader.string(); _ = try? reader.attributes(); _ = try? reader.bytes(); _ = try? reader.uint64()

            let text = String(decoding: body, as: UTF8.self)
            _ = RemoteSearch.parse(line: body, ripgrep: true)
            _ = RemoteSearch.parse(line: body, ripgrep: false)
            _ = SSHConfig.split(text)
            _ = SSHConfig.words(text)
            _ = FileListing.parse(body)
            _ = SSHConnection.stage(from: text)
        }
    }
}
