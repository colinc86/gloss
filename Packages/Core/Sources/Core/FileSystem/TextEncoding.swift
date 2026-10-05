import Foundation

/// The encoding a text file was read in, so it is written back in the same one. Files are UTF-8 unless their bytes
/// say otherwise: a UTF-16 byte-order mark, or bytes that aren't valid UTF-8 (then Windows-1252, which every
/// Latin-1 file outside 0x80–0x9F also is, and Latin-1 as the decoding that never fails).
public enum TextEncoding: String, Sendable, Equatable {
    case utf8
    /// UTF-8 behind an EF BB BF mark (common in Windows projects); the mark is kept on save.
    case utf8WithBOM
    case utf16LittleEndian
    case utf16BigEndian
    case windows1252
    case latin1

    /// Decodes `data` and reports the encoding used. Every result round-trips: `encode(decode(data).text)` gives
    /// back the same bytes.
    public static func decode(_ data: Data) -> (text: String, encoding: TextEncoding) {
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE], let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (text, .utf16LittleEndian)
        }
        if bytes == [0xFE, 0xFF], let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (text, .utf16BigEndian)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return (text, .utf8WithBOM)
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let text = String(data: data, encoding: .windowsCP1252), text.data(using: .windowsCP1252) == data {
            return (text, .windows1252)
        }
        return (String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self), .latin1)
    }

    /// The bytes for `text` in this encoding (with the byte-order mark for UTF-16), or nil when it holds a character
    /// the encoding can't represent. Never falls back to another encoding: that would rewrite the whole file.
    public func encode(_ text: String) -> Data? {
        switch self {
        case .utf8: Data(text.utf8)
        case .utf8WithBOM: Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16LittleEndian: text.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        case .utf16BigEndian: text.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        case .windows1252: text.data(using: .windowsCP1252, allowLossyConversion: false)
        case .latin1: text.data(using: .isoLatin1, allowLossyConversion: false)
        }
    }

    /// Unicode encodings hold any text; the others can't take every character a user may type.
    public var isUnicode: Bool { self != .windows1252 && self != .latin1 }

    /// True when `data` would be valid UTF-8 but for an incomplete sequence in its last 1–3 bytes: a file read while
    /// another process is still writing it, not a file in another encoding.
    public static func isUTF8CutShort(_ data: Data) -> Bool {
        guard String(data: data, encoding: .utf8) == nil else { return false }
        for drop in 1...3 where data.count > drop {
            if String(data: data.dropLast(drop), encoding: .utf8) != nil {
                // The dropped bytes must be the start of one multibyte character: a lead byte, then only
                // continuation bytes, fewer than the lead promises. Anything else is another encoding.
                let tail = Array(data.suffix(drop))
                let expected = tail[0] >= 0xF0 && tail[0] <= 0xF4 ? 4 : tail[0] >= 0xE0 ? 3 : tail[0] >= 0xC2 ? 2 : 0
                return expected > drop && tail.dropFirst().allSatisfy { $0 & 0xC0 == 0x80 }
            }
        }
        return false
    }

    public var displayName: String {
        switch self {
        case .utf8, .utf8WithBOM: "UTF-8"
        case .utf16LittleEndian, .utf16BigEndian: "UTF-16"
        case .windows1252: "Windows-1252"
        case .latin1: "Latin-1"
        }
    }
}
