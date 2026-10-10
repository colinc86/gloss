import Foundation

/// Ranks file paths against a typed query for Open Quickly. Every query character must appear in order
/// (ignoring case and accents). Matches score higher at the start of a path component or a word (`Model` in
/// `AppModel`, `m` after `_`), in runs of consecutive characters, and in the file name rather than its folders;
/// shorter paths win ties.
public enum FuzzyMatcher {
    /// Nil when `query` is not a subsequence of `path`. Higher is better.
    public static func score(query: String, path: String) -> Int? {
        let needle = folded(query.filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let original = Array(path)
        let haystack = folded(path)
        let nameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0

        // Prefer an alignment inside the file name: try matching the query within the name first.
        if let inName = align(needle, haystack, original, from: nameStart) { return inName.score + 1_000 - path.count }
        guard let anywhere = align(needle, haystack, original, from: 0) else { return nil }
        return anywhere.score - path.count
    }

    /// A string's characters as they are compared. Most paths are ASCII, where lowercasing the whole string is all
    /// folding does, and much quicker than a character at a time.
    static func folded(_ text: String) -> [Character] {
        text.utf8.allSatisfy { $0 < 0x80 } ? Array(text.lowercased()) : text.map(fold)
    }

    /// One character as it is compared: lowercase, and without its accents (`resume` finds `Résumé.md`, as the notes
    /// panel's search does), always one character so positions in the path keep their meaning.
    static func fold(_ character: Character) -> Character {
        if character.isASCII { return Character(character.lowercased()) }
        let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if folded.count == 1, let only = folded.first { return only }
        let lowered = character.lowercased()
        return lowered.count == 1 ? Character(lowered) : character
    }

    /// The best `limit` paths for `query`, best first; all paths (shortest first) when the query is empty.
    public static func rank(_ query: String, in paths: [String], limit: Int = 50) -> [String] {
        if query.allSatisfy(\.isWhitespace) { return Array(paths.sorted { ($0.count, $0) < ($1.count, $1) }.prefix(limit)) }
        var scored: [(path: String, score: Int)] = []
        for (offset, path) in paths.enumerated() {
            // A newer keystroke cancels this ranking: stop rather than finish work nobody will see.
            if offset % 1_024 == 0, Task.isCancelled { return [] }
            if let score = score(query: query, path: path) { scored.append((path, score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        return scored.prefix(limit).map(\.path)
    }

    /// Left-to-right alignment that prefers word starts, without ever giving up a match: `latest[i]` is the last
    /// position query character `i` can take and still leave room for the rest, so a word-start candidate past it
    /// is skipped for the plain occurrence (a greedy pick of the later `a` in `xab_a` used to lose `ab`).
    private static func align(_ needle: [Character], _ haystack: [Character], _ original: [Character], from start: Int) -> (score: Int, matched: Bool)? {
        var latest = [Int](repeating: -1, count: needle.count)
        var position = haystack.count - 1
        for index in needle.indices.reversed() {
            while position >= start, haystack[position] != needle[index] { position -= 1 }
            guard position >= start else { return nil }
            latest[index] = position
            position -= 1
        }
        var score = 0
        position = start
        var previous = -2
        for (offset, character) in needle.enumerated() {
            var chosen: Int?
            var fallback: Int?
            var index = position
            while index <= latest[offset] {
                if haystack[index] == character {
                    if fallback == nil { fallback = index }
                    if index == previous + 1 || isWordStart(index, original) { chosen = index; break }
                }
                index += 1
            }
            guard let match = chosen ?? fallback else { return nil }
            score += 10
            if match == previous + 1 { score += 15 }
            if isWordStart(match, original) { score += 20 }
            previous = match
            position = match + 1
        }
        return (score, true)
    }

    private static func isWordStart(_ index: Int, _ characters: [Character]) -> Bool {
        guard index > 0 else { return true }
        let before = characters[index - 1]
        let current = characters[index]
        if "/._- ".contains(before) { return true }
        return current.isUppercase && before.isLowercase
    }
}
