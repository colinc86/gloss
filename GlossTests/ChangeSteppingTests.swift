import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

@MainActor
struct ChangeSteppingTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func stepsThroughHunksFromTheCaretAndWraps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-hunks-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try (1...30).map { "line \($0)" }.joined(separator: "\n").write(toFile: "\(root)/a.swift", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        model.openDocument(hostID: .local, path: "\(root)/a.swift")
        let session = try #require(model.activeSession)
        await waitUntil { session.textController != nil }
        let controller = try #require(session.textController)
        #expect(session.changeHunks.isEmpty && !session.stepChange(forward: true), "nothing to step to without changes")

        controller.lineChanges = LineChanges(added: [5...6, 20...22], deletions: [12])
        #expect(session.changeHunks.map(\.key) == [5, 12, 20])
        #expect(session.stepChange(forward: true))
        #expect(session.changePosition?.index == 1 && session.changePosition?.count == 3)
        #expect(controller.pendingScroll == controller.lineIndex.contentRange(ofLine: 5))
        session.stepChange(forward: true)
        session.stepChange(forward: true)
        #expect(session.changePosition?.index == 3)
        session.stepChange(forward: true)
        #expect(session.changePosition?.index == 1, "wraps")
        session.stepChange(forward: false)
        #expect(session.changePosition?.index == 3)
        await model.shutDown()
    }
}
