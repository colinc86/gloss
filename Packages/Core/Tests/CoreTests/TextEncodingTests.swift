import Foundation
import Testing
@testable import Core

struct TextEncodingTests {
    @Test func everyEncodingRoundTripsItsBytes() {
        let samples: [(Data, TextEncoding)] = [
            (Data("café ☕\r\n".utf8), .utf8),
            (Data([0xFF, 0xFE]) + "héllo €".data(using: .utf16LittleEndian)!, .utf16LittleEndian),
            (Data([0xFE, 0xFF]) + "héllo €".data(using: .utf16BigEndian)!, .utf16BigEndian),
            (Data([0x93, 0x71, 0x94, 0x20, 0x80]), .windows1252),          // “q” €
            (Data([0x6E, 0x61, 0xFF, 0x76, 0x81]), .latin1),               // 0x81 is undefined in Windows-1252
        ]
        for (data, expected) in samples {
            let (text, encoding) = TextEncoding.decode(data)
            #expect(encoding == expected, "\(data as NSData)")
            #expect(encoding.encode(text) == data, "\(expected) round trip")
        }
    }

    @Test func aCharacterTheEncodingCantHoldIsRefusedNotConverted() {
        #expect(TextEncoding.latin1.encode("na\u{EF}ve") == Data([0x6E, 0x61, 0xEF, 0x76, 0x65]))
        #expect(TextEncoding.latin1.encode("arrow →") == nil)
        #expect(TextEncoding.windows1252.encode("emoji 😀") == nil)
        #expect(TextEncoding.utf16LittleEndian.encode("😀") != nil)
    }
}
