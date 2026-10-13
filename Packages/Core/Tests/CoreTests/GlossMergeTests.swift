import Foundation
import Testing
@testable import Core

/// Merging versions of one package (iCloud conflict versions, a duplicate `Review 2.gloss`) and the copy rule.
struct GlossMergeTests {
    func duplicate(_ url: URL, as name: String, in fixture: GlossFixture) throws -> URL {
        let copy = fixture.folder.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    @Test func twoOfflineVersionsMergeToTheSameTreeEitherWay() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let shared = try owner.writeNote(fixture.note(by: fixture.owner, "Original"))
        let other = try duplicate(fixture.url, as: "Review of README 2.gloss", in: fixture)

        // Mac A: the participant posts a note and resolves the owner's; the owner edits its note.
        let participantA = try fixture.writer(fixture.participant)
        try participantA.writeAuthor(name: "Morgan", joinedAt: fixture.start)
        let posted = try participantA.writeNote(fixture.note(by: fixture.participant, "From Morgan"))
        try participantA.writeEvent(.resolved(shared.id, by: fixture.participant, at: fixture.start + 40))
        var editA = shared
        editA.body = "Edited on A"
        try owner.writeNote(editA)

        // Mac B, later: the owner edits the same note again and publishes a new iteration.
        var ownerB = try GlossPackageWriter(package: GlossPackage(url: other), author: fixture.owner)
        var editB = shared
        editB.body = "Edited on B"
        try ownerB.writeNote(editB)
        let ownNote = try ownerB.writeNote(fixture.note(by: fixture.owner, "Second note"))
        try ownerB.publish(iteration: 1, content: Data("# Read me\n\nChanged.\n".utf8), ext: "md", at: fixture.start + 90)

        let a2 = try duplicate(fixture.url, as: "A2.gloss", in: fixture)
        let b2 = try duplicate(other, as: "B2.gloss", in: fixture)
        let intoA = try GlossMerge.merge([fixture.url, other], into: fixture.url)
        let intoB = try GlossMerge.merge([a2], into: b2)
        #expect(intoA.treeHash == intoB.treeHash, "every Mac converges on the same files")
        #expect(intoA.anomalies.isEmpty)

        let merged = try GlossPackage(url: fixture.url).read()
        #expect(Set(merged.notes.map(\.id)) == [shared.id, posted.id, ownNote.id], "nothing is lost")
        #expect(merged.notes.first { $0.id == shared.id }?.body == "Edited on B", "the later rewrite wins")
        #expect(merged.info.current.iteration == 1 && merged.hasCurrentContent)
        #expect(merged.iterations.map(\.number) == [0, 1] && merged.iterations[0].endedAt != nil, "the ended iteration wins over the open one")
        #expect(merged.folded().first { $0.id == shared.id }?.status == .resolved)
        #expect(merged.author(fixture.participant)?.name == "Morgan")
    }

    @Test func mergingTwiceChangesNothing() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let other = try duplicate(fixture.url, as: "Other.gloss", in: fixture)
        try owner.writeNote(fixture.note(by: fixture.owner))
        let first = try GlossMerge.merge([other], into: fixture.url)
        let second = try GlossMerge.merge([other], into: fixture.url)
        #expect(second.written.isEmpty && first.treeHash == second.treeHash)
    }

    @Test func aWriteOnceFileWithTwoContentsResolvesTheSameWayEverywhere() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let note = try owner.writeNote(fixture.note(by: fixture.owner))
        let other = try duplicate(fixture.url, as: "Other.gloss", in: fixture)
        let id = EventID.new()
        try owner.writeEvent(GlossEvent(id: id, note: note.id, author: fixture.owner, type: .resolved, at: fixture.start))
        try GlossPackageWriter(package: GlossPackage(url: other), author: fixture.owner)
            .writeEvent(GlossEvent(id: id, note: note.id, author: fixture.owner, type: .reopened, at: fixture.start))

        let a2 = try duplicate(fixture.url, as: "A2.gloss", in: fixture)
        let b2 = try duplicate(other, as: "B2.gloss", in: fixture)
        let intoA = try GlossMerge.merge([other], into: fixture.url)
        let intoB = try GlossMerge.merge([a2], into: b2)
        #expect(intoA.treeHash == intoB.treeHash)
        #expect(intoA.anomalies.map(\.path) == [GlossLayout.event(id, by: fixture.owner)])
    }

    @Test func threeVersionsConvergeInAnyOrder() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        _ = try fixture.create()
        var versions: [URL] = [fixture.url]
        for index in 1...2 { versions.append(try duplicate(fixture.url, as: "V\(index).gloss", in: fixture)) }
        for (index, version) in versions.enumerated() {
            let author = index == 0 ? fixture.owner : AuthorID.new()
            let writer = try GlossPackageWriter(package: GlossPackage(url: version), author: author)
            try writer.writeAuthor(name: "Person \(index)", joinedAt: fixture.start)
            try writer.writeNote(fixture.note(by: author, "Note \(index)"))
        }
        var hashes: Set<String> = []
        for (round, order) in [[0, 1, 2], [2, 1, 0], [1, 0, 2]].enumerated() {
            let copies = try order.enumerated().map { try duplicate(versions[$0.element], as: "R\(round)-\($0.offset).gloss", in: fixture) }
            // Pairwise, in a different grouping each time, then all at once.
            _ = try GlossMerge.merge([copies[1]], into: copies[0])
            hashes.insert(try GlossMerge.merge([copies[2]], into: copies[0]).treeHash)
        }
        hashes.insert(try GlossMerge.merge(versions, into: versions[2]).treeHash)
        #expect(hashes.count == 1)
        #expect(try GlossPackage(url: versions[2]).read().notes.count == 3)
    }

    @Test func unreadableAndMismatchedFilesLose() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let note = try owner.writeNote(fixture.note(by: fixture.owner))
        let attachment = try owner.addAttachment(Data([1, 2, 3]), ext: "png")
        let other = try duplicate(fixture.url, as: "Other.gloss", in: fixture)
        let otherPackage = GlossPackage(url: other)
        try Data("{ broken".utf8).write(to: otherPackage.fileURL(GlossLayout.note(note.id, by: fixture.owner)))
        try Data([9, 9, 9]).write(to: otherPackage.fileURL(attachment))

        let report = try GlossMerge.merge([fixture.url], into: other)
        #expect(try otherPackage.read().notes.first?.body == note.body, "the readable note wins")
        #expect(try Data(contentsOf: otherPackage.fileURL(attachment)) == Data([1, 2, 3]), "the bytes matching the name win")
        #expect(report.anomalies.map(\.path) == [attachment])
    }

    @Test func infoAndTheCurrentIterationAgreeAfterAMerge() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        _ = try fixture.create()
        let other = try duplicate(fixture.url, as: "Other.gloss", in: fixture)
        // The owner on two Macs, offline, publishes iteration 1 with different content on each.
        var a = try fixture.writer(fixture.owner)
        try a.publish(iteration: 1, content: Data("A".utf8), ext: "md", at: fixture.start + 100)
        var b = try GlossPackageWriter(package: GlossPackage(url: other), author: fixture.owner)
        try b.publish(iteration: 1, content: Data("B".utf8), ext: "md", at: fixture.start + 50)

        let b2 = try duplicate(other, as: "B2.gloss", in: fixture)
        let a2 = try duplicate(fixture.url, as: "A2.gloss", in: fixture)
        #expect(try GlossMerge.merge([other], into: fixture.url).treeHash == GlossMerge.merge([a2], into: b2).treeHash)
        let merged = try GlossPackage(url: fixture.url).read()
        #expect(merged.info.current.hash == Data("A".utf8).sha256Hex, "the later capture wins")
        #expect(merged.iterations.first { $0.number == 1 }?.snapshot == merged.info.current.hash)
        #expect(merged.snapshots.contains(Data("B".utf8).sha256Hex), "the losing capture is kept, not deleted")
    }

    @Test func anAdoptedOwnerSurvivesAConcurrentOwnerWrite() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        _ = try fixture.create()
        let other = try duplicate(fixture.url, as: "Other.gloss", in: fixture)
        // The owner's second Mac adopts the review while the first, offline, publishes an iteration.
        let mini = AuthorID.new()
        var adopting = try fixture.writer(mini)
        #expect(try adopting.adoptOwnership(name: "Alex", at: fixture.start + 10))
        var first = try GlossPackageWriter(package: GlossPackage(url: other), author: fixture.owner)
        try first.publish(iteration: 1, content: Data("Changed".utf8), ext: "md", at: fixture.start + 20)

        let other2 = try duplicate(other, as: "Other2.gloss", in: fixture)
        let mine2 = try duplicate(fixture.url, as: "Mine2.gloss", in: fixture)
        #expect(try GlossMerge.merge([other], into: fixture.url).treeHash == GlossMerge.merge([mine2], into: other2).treeHash)
        let merged = try GlossPackage(url: fixture.url).readInfo()
        #expect(merged.current.iteration == 1, "the iteration wins")
        #expect(merged.owners == [fixture.owner, mini], "and the adoption is kept")
    }

    @Test func infoWithoutOwnerAuthorsReadsAsOneOwner() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        _ = try fixture.create()
        let info = try GlossPackage(url: fixture.url).readInfo()
        #expect(info.ownerAuthors == nil && info.owners == [fixture.owner])
        #expect(try !String(decoding: Data(contentsOf: GlossPackage(url: fixture.url).fileURL(GlossFormat.infoFile)), as: UTF8.self).contains("ownerAuthors"))
    }

    @Test func folderCaptureMembersAreCheckedAgainstTheirManifest() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        let hash = try owner.addSnapshotFolder(["dom.html": Data("<p>".utf8), "shot.png": Data([1])])
        let other = try duplicate(fixture.url, as: "Other.gloss", in: fixture)
        try Data([2]).write(to: GlossPackage(url: other).fileURL("content/\(hash)/shot.png"))
        _ = try GlossMerge.merge([fixture.url], into: other)
        #expect(try Data(contentsOf: GlossPackage(url: other).fileURL("content/\(hash)/shot.png")) == Data([1]))
    }

    @Test func aCopyIsANewInstanceThatNeverRejoins() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        let owner = try fixture.create()
        try owner.writeNote(fixture.note(by: fixture.owner))
        let original = try GlossPackage(url: fixture.url).readInfo()
        let copyURL = fixture.folder.appending(path: "Copy.gloss", directoryHint: .isDirectory)
        let copy = try GlossPackage(url: fixture.url).makeCopy(to: copyURL, at: fixture.start + 500)

        #expect(copy.instance != original.instance)
        #expect(copy.id == original.id && copy.ownerAuthor == original.ownerAuthor, "the review and its history stay")
        #expect(copy.origin == GlossOrigin(review: original.id, instance: original.instance, iteration: 0, copiedAt: fixture.start + 500))
        #expect(try GlossPackage(url: copyURL).read().notes.count == 1)
        #expect(throws: GlossPackageError.differentInstances) { try GlossMerge.merge([copyURL], into: fixture.url) }
        #expect(throws: GlossPackageError.differentInstances) { try GlossMerge.merge([fixture.url], into: copyURL) }
        #expect(try GlossPackage(url: fixture.url).readInfo() == original, "the original is untouched")
    }

    @Test func refusesToOverwriteWhenCopying() throws {
        let fixture = try GlossFixture()
        defer { fixture.remove() }
        _ = try fixture.create()
        #expect(throws: GlossPackageError.alreadyExists(fixture.url.path)) { try GlossPackage(url: fixture.url).makeCopy(to: fixture.url) }
    }
}
