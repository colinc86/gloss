import Foundation
import Testing
@testable import Core

struct LineDiffTests {
    func apply(_ edits: [DiffEdit], old: [String], new: [String]) -> [String] {
        edits.compactMap { edit in
            switch edit {
            case .equal(let o, _): old[o]
            case .insert(let n): new[n]
            case .delete: nil
            }
        }
    }

    @Test func diffReconstructsTheNewSide() {
        let old = ["a", "b", "c", "d", "e"]
        let new = ["a", "x", "c", "e", "f"]
        let edits = LineDiff.diff(old: old, new: new)
        #expect(apply(edits, old: old, new: new) == new)
        #expect(LineDiff.hunks(old: old, new: new) == [DiffHunk(oldRange: 1..<2, newRange: 1..<2), DiffHunk(oldRange: 3..<4, newRange: 3..<3), DiffHunk(oldRange: 5..<5, newRange: 4..<5)])
    }

    @Test func emptyAndIdenticalInputs() {
        #expect(LineDiff.diff(old: [], new: []).isEmpty)
        #expect(LineDiff.hunks(old: ["a"], new: ["a"]).isEmpty)
        #expect(LineDiff.hunks(old: [], new: ["a", "b"]) == [DiffHunk(oldRange: 0..<0, newRange: 0..<2)])
        #expect(LineDiff.hunks(old: ["a", "b"], new: []) == [DiffHunk(oldRange: 0..<2, newRange: 0..<0)])
    }

    @Test func randomizedRoundTrip() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let old = (0..<Int.random(in: 0..<40, using: &generator)).map { _ in String(Int.random(in: 0..<6, using: &generator)) }
            let new = (0..<Int.random(in: 0..<40, using: &generator)).map { _ in String(Int.random(in: 0..<6, using: &generator)) }
            #expect(apply(LineDiff.diff(old: old, new: new), old: old, new: new) == new)
        }
    }
}

struct ThreeWayMergeTests {
    let base = ["one", "two", "three", "four", "five", "six"]

    @Test func nonOverlappingChangesMergeCleanly() {
        let mine = ["one", "TWO", "three", "four", "five", "six"]
        let theirs = ["one", "two", "three", "four", "FIVE", "six", "seven"]
        let regions = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(!regions.contains { $0.isConflict })
        #expect(ThreeWayMerge.resolve(regions) == ["one", "TWO", "three", "four", "FIVE", "six", "seven"])
    }

    @Test func identicalChangesAreNotConflicts() {
        let edited = ["one", "2", "three", "four", "five", "six"]
        let regions = ThreeWayMerge.merge(base: base, mine: edited, theirs: edited)
        #expect(regions == [.unchanged(["one"]), .both(["2"]), .unchanged(["three", "four", "five", "six"])])
    }

    @Test func overlappingDifferentChangesConflict() {
        let mine = ["one", "two-mine", "three", "four", "five", "six"]
        let theirs = ["one", "two-theirs", "three", "four", "five", "six"]
        let regions = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(regions.contains(.conflict(mine: ["two-mine"], theirs: ["two-theirs"])))
        #expect(ThreeWayMerge.resolve(regions) == nil)
    }

    @Test func insertionsAtTheSameSpotConflict() {
        let mine = ["one", "mine", "two", "three", "four", "five", "six"]
        let theirs = ["one", "theirs", "two", "three", "four", "five", "six"]
        let regions = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(regions.contains { $0.isConflict })
    }

    @Test func oneSideUnchangedTakesTheOther() {
        let theirs = ["zero", "one", "two", "three", "four", "five"]
        let regions = ThreeWayMerge.merge(base: base, mine: base, theirs: theirs)
        #expect(ThreeWayMerge.resolve(regions) == theirs)
    }
}
