import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

@MainActor
@Suite(.serialized)
struct MotionTests {
    @Test func reduceMotionCalmsEveryCurveAndStopsLoops() {
        defer { Motion.reducedOverride = nil }
        Motion.reducedOverride = true
        #expect(Motion.isReduced)
        #expect(!Motion.allowsLooping)
        #expect(Motion.snappy == Motion.smooth)
        #expect(Motion.smooth == Motion.bouncy)

        Motion.reducedOverride = false
        #expect(!Motion.isReduced)
        #expect(Motion.allowsLooping)
        #expect(Motion.snappy != Motion.bouncy)
        #expect(Motion.smooth == .smooth(duration: 0.28))
    }
}

@MainActor
struct HighlightAppearanceTests {
    @Test func darkTintsAreStrongerThanLight() throws {
        let tint = Theme.highlightBackground(for: NoteHighlight(id: .new(), anchor: .wholeFile, color: .yellow, state: .draft))
        func alpha(_ name: NSAppearance.Name) throws -> CGFloat {
            var value: CGFloat = 0
            try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                value = tint.usingColorSpace(.sRGB)?.alphaComponent ?? 0
            }
            return value
        }
        #expect(abs(try alpha(.aqua) - 0.28) < 0.01)
        #expect(abs(try alpha(.darkAqua) - 0.28 * Theme.darkBoost) < 0.01)
    }
}
