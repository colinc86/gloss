import Foundation
import Synchronization

/// Universally Unique Lexicographically Sortable Identifier: 48-bit millisecond timestamp
/// followed by 80 random bits, encoded as 26 Crockford base32 characters.
/// Values minted by one process are strictly increasing, even within a millisecond.
public enum ULID {
    public static let length = 26

    static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let decodeTable: [Character: UInt128] = {
        var table: [Character: UInt128] = [:]
        for (index, character) in alphabet.enumerated() {
            table[character] = UInt128(index)
            table[Character(character.lowercased())] = UInt128(index)
        }
        // Crockford aliases.
        table["O"] = 0; table["o"] = 0
        table["I"] = 1; table["i"] = 1; table["L"] = 1; table["l"] = 1
        return table
    }()

    private struct State {
        var lastTime: UInt64 = 0
        var lastRandom: UInt128 = 0
    }

    private static let state = Mutex(State())
    private static let randomMask: UInt128 = (UInt128(1) << 80) - 1

    /// Mints a new identifier for the current time.
    public static func generate(now: Date = Date()) -> String {
        let milliseconds = UInt64(max(0, (now.timeIntervalSince1970 * 1000).rounded()))
        let value: UInt128 = state.withLock { state in
            if milliseconds != state.lastTime {
                state.lastTime = milliseconds
                state.lastRandom = randomBits()
            } else {
                // Same millisecond: keep ids monotonic by bumping the random part.
                state.lastRandom &+= 1
                if state.lastRandom > randomMask {
                    state.lastTime += 1
                    state.lastRandom = 0
                }
            }
            return (UInt128(state.lastTime) << 80) | state.lastRandom
        }
        return encode(value)
    }

    /// Decodes a 26-character identifier into its 128-bit value, or nil when malformed.
    public static func decode(_ string: String) -> UInt128? {
        guard string.count == length else { return nil }
        var value: UInt128 = 0
        for character in string {
            guard let digit = decodeTable[character] else { return nil }
            value = (value << 5) | digit
        }
        // The first character may only carry 3 bits (128 = 25 * 5 + 3).
        guard let first = string.first, let firstDigit = decodeTable[first], firstDigit < 8 else { return nil }
        return value
    }

    /// The millisecond timestamp embedded in an identifier.
    public static func timestamp(of string: String) -> Date? {
        guard let value = decode(string) else { return nil }
        let milliseconds = UInt64(truncatingIfNeeded: value >> 80)
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    public static func isValid(_ string: String) -> Bool {
        decode(string) != nil
    }

    static func encode(_ value: UInt128) -> String {
        var characters: [Character] = []
        characters.reserveCapacity(length)
        for index in 0..<length {
            let shift = UInt128(5 * (length - 1 - index))
            let digit = Int(truncatingIfNeeded: (value >> shift) & 0x1F)
            characters.append(alphabet[digit])
        }
        return String(characters)
    }

    private static func randomBits() -> UInt128 {
        var generator = SystemRandomNumberGenerator()
        let high = UInt128(UInt64.random(in: 0...0xFFFF, using: &generator))
        let low = UInt128(UInt64.random(in: .min ... .max, using: &generator))
        return (high << 64) | low
    }
}
