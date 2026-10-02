import Foundation
import Testing
@testable import Core

struct ULIDTests {
    @Test func hasLengthAndCharset() {
        let id = ULID.generate()
        #expect(id.count == 26)
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        #expect(id.allSatisfy { allowed.contains($0) })
    }

    @Test func isMonotonicWithinOneMillisecond() {
        let now = Date()
        var previous = ULID.generate(now: now)
        for _ in 0..<1000 {
            let next = ULID.generate(now: now)
            #expect(next > previous, "ids minted in the same millisecond must increase")
            previous = next
        }
    }

    @Test func sortsByTime() {
        let earlier = ULID.generate(now: Date(timeIntervalSince1970: 1_700_000_000))
        let later = ULID.generate(now: Date(timeIntervalSince1970: 1_700_000_100))
        #expect(earlier < later)
    }

    @Test func roundTripsTimestamp() throws {
        // Built directly rather than through generate(now:), which never moves the process clock backwards.
        let id = ULID.encode(UInt128(1_727_740_800_123) << 80 | 42)
        let decoded = try #require(ULID.timestamp(of: id))
        #expect(abs(decoded.timeIntervalSince1970 - 1_727_740_800.123) < 0.001)
        #expect(ULID.decode(id) == UInt128(1_727_740_800_123) << 80 | 42)
    }

    @Test func generateNeverGoesBackwards() {
        // One second ahead, so the shared clock state is not left far in the future for later tests.
        let later = ULID.generate(now: Date(timeIntervalSinceNow: 1))
        let earlierClock = ULID.generate(now: Date(timeIntervalSinceNow: -3600))
        #expect(earlierClock > later)
    }

    @Test func rejectsMalformed() {
        #expect(ULID.decode("") == nil)
        #expect(ULID.decode("01ARZ3NDEKTSV4RRFFQ69G5FA") == nil)   // 25 chars
        #expect(ULID.decode("U1ARZ3NDEKTSV4RRFFQ69G5FAV") == nil)  // U is not in the alphabet
        #expect(ULID.decode("81ARZ3NDEKTSV4RRFFQ69G5FAV") == nil)  // overflow in the first char
        #expect(ULID.isValid("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
    }

    @Test func encodesKnownValue() {
        #expect(ULID.encode(0) == "00000000000000000000000000")
        #expect(ULID.encode(31) == "0000000000000000000000000Z")
    }
}

struct TypedIDTests {
    @Test func newCarriesPrefix() {
        let id = NoteID.new()
        #expect(id.rawValue.hasPrefix("n_"))
        #expect(id.rawValue.count == 28)
        #expect(id.createdAt != nil)
    }

    @Test func validatingChecksPrefixAndBody() {
        #expect(NoteID(validating: "n_01ARZ3NDEKTSV4RRFFQ69G5FAV") != nil)
        #expect(NoteID(validating: "d_01ARZ3NDEKTSV4RRFFQ69G5FAV") == nil)
        #expect(NoteID(validating: "n_nope") == nil)
        #expect(HostID(validating: "h_local") == HostID.local)
        #expect(HostID(validating: "h_nope") == nil)
        #expect(DocumentID(validating: "d_01ARZ3NDEKTSV4RRFFQ69G5FAV") != nil)
    }

    @Test func codableAsPlainString() throws {
        let id = NoteID(rawValue: "n_01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == "[\"n_01ARZ3NDEKTSV4RRFFQ69G5FAV\"]")
        let back = try JSONDecoder().decode([NoteID].self, from: data)
        #expect(back == [id])
    }

    @Test func localHostIsStable() {
        #expect(HostID.local.rawValue == "h_local")
    }
}
