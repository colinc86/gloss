import CoreGraphics
import Foundation
import Testing
@testable import Gloss

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
}
