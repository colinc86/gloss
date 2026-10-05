import Foundation
import Testing
@testable import Core

struct TextEncodingTests {
    @Test func everyEncodingRoundTripsItsBytes() {
        let samples: [(Data, TextEncoding)] = [
            (Data("café ☕\r\n".utf8), .utf8),
            (Data([0xEF, 0xBB, 0xBF]) + Data("Write-Host 'é'\r\n".utf8), .utf8WithBOM),
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

    @Test func aUTF8FileReadMidWriteIsRecognised() {
        let full = Data("héllo wörld é".utf8)
        #expect(TextEncoding.isUTF8CutShort(full.dropLast()))
        #expect(!TextEncoding.isUTF8CutShort(full), "complete UTF-8 ending in a multibyte character")
        #expect(!TextEncoding.isUTF8CutShort(Data([0x61, 0x62, 0xE9, 0x20, 0x63])), "Latin-1 é mid-text is not a cut")
    }

    @Test func aCharacterTheEncodingCantHoldIsRefusedNotConverted() {
        #expect(TextEncoding.latin1.encode("na\u{EF}ve") == Data([0x6E, 0x61, 0xEF, 0x76, 0x65]))
        #expect(TextEncoding.latin1.encode("arrow →") == nil)
        #expect(TextEncoding.windows1252.encode("emoji 😀") == nil)
        #expect(TextEncoding.utf16LittleEndian.encode("😀") != nil)
    }
}
