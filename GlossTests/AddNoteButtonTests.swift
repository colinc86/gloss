import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Gloss

@MainActor
struct AddNoteButtonTests {
    @Test func sitsAboveTheSelectionsTrailingEdgeAndStaysInside() {
        let size = AddNoteButton.size
        let bounds = CGSize(width: 800, height: 600)
        // Plenty of room above: centered on the selection's right edge, one gap above it.
        let above = AddNoteButton.placement(for: CGRect(x: 100, y: 200, width: 300, height: 40), in: bounds)
        #expect(above.x == 400 - size.width / 2)
        #expect(above.y == 200 - 8 - size.height / 2)
        // No room above: below the selection instead.
        let below = AddNoteButton.placement(for: CGRect(x: 100, y: 4, width: 300, height: 40), in: bounds)
        #expect(below.y == 44 + 8 + size.height / 2)
        // Never off the trailing or leading edge.
        let right = AddNoteButton.placement(for: CGRect(x: 700, y: 300, width: 300, height: 20), in: bounds)
        #expect(right.x + size.width / 2 <= bounds.width - 8)
        let left = AddNoteButton.placement(for: CGRect(x: -50, y: 300, width: 20, height: 20), in: bounds)
        #expect(left.x - size.width / 2 >= 8)
    }

    /// The button grows out of the selection's edge it sits against: below itself when above the text, above
    /// itself when below; under its middle, or under the selection when that is narrower than the button.
    @Test func emergesFromTheSelectedLine() {
        let bounds = CGSize(width: 800, height: 600)
        let height = AddNoteButton.size.height
        let above = AddNoteButton.emergence(for: CGRect(x: 100, y: 200, width: 300, height: 20), in: bounds)
        #expect(above.x == 0.5)
        #expect(abs(above.y - (height + 8) / height) < 0.001, "the selection's top, one gap under the button")
        let below = AddNoteButton.emergence(for: CGRect(x: 100, y: 4, width: 300, height: 20), in: bounds)
        #expect(abs(below.y - (-8 / height)) < 0.001, "the selection's bottom, one gap over the button")
        let narrow = AddNoteButton.emergence(for: CGRect(x: 380, y: 200, width: 20, height: 20), in: bounds)
        #expect(narrow.x > 0.5 && narrow.x <= 1, "toward the short selection under the button's trailing half")
    }
}
