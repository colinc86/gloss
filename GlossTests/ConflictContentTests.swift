import AppKit
import Core
import SwiftUI
import Testing
@testable import Gloss

/// What the conflict sheet says, and how it looks for a merge and for a real conflict.
@MainActor
struct ConflictContentTests {
    static let mergeable: [MergeRegion] = [
        .unchanged(["import Foundation", "", "/// One leg of the route.", "struct Segment {", "    let name: String"]),
        .mine(["    let kilometres: Double // rounded"]),
        .unchanged(["    let climb: Int", "}"]),
        .theirs(["/// Added on disk", "enum Difficulty { case easy, steep }"]),
    ]
    static let conflicting: [MergeRegion] = [
        .unchanged(["struct Segment {"]),
        .conflict(mine: ["    let name: String // mine"], theirs: ["    let title: String"]),
        .both(["}"]),
    ]

    @Test func summariesCountEachKindOfChange() {
        #expect(ConflictContent.summary(Self.mergeable) == "1 change of yours · 1 change from disk")
        #expect(ConflictContent.summary(Self.conflicting) == "1 made on both sides · 1 conflict")
        #expect(ConflictContent.summary([.unchanged(["a"])]) == "No differences")
    }

    @Test func rendersBothCases() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-conflict")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, regions, merge) in [("merge", Self.mergeable, true), ("conflict", Self.conflicting, false)] {
            let view = ConflictContent(fileName: "trail.swift", regions: regions, canMerge: merge, canSaveAs: true,
                                       saveAs: {}, takeDisk: {}, keepMine: {}, merge: {}, scrolls: false)
                .frame(width: 760, height: 520)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let tiff = try #require(renderer.nsImage?.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
}
