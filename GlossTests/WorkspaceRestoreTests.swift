import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

/// Issue #9: quitting and opening again brings back what was open, unless Settings or the Mac says not to.
@MainActor
struct WorkspaceRestoreTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func theWorkspaceRoundTripsAndReadsTheOldSetting() throws {
        var workspace = Workspace()
        workspace.folders = [.init(host: "local", path: "/a"), .init(host: "h_box", path: "/home/me")]
        workspace.selectedFolder = 1
        workspace.document = .init(place: .init(host: "h_box", path: "/home/me/plan.md"), line: 40, showsSource: true)
        workspace.back = [.init(host: "local", path: "/a/README.md")]
        workspace.showsNotesPanel = false
        let value = try #require(workspace.encoded())
        #expect(Workspace.decoded(value) == workspace)
        #expect(Workspace.decoded("not json") == nil)
        let old = try #require(Workspace.fromLastDocument("local\n/a/b.swift\n12"))
        #expect(old.document == .init(place: .init(host: "local", path: "/a/b.swift"), line: 12))
        #expect(old.folders.isEmpty)
    }

    @Test func asMyMacDoesFollowsTheSystemSetting() {
        #expect(LaunchRestore.system.resolved(keepsWindows: true) == .everything)
        #expect(LaunchRestore.system.resolved(keepsWindows: false) == .lastFolder, "closing windows on quit still reopens the folder, as before")
        #expect(LaunchRestore.nothing.resolved(keepsWindows: true) == .nothing, "an explicit choice wins")
        #expect(LaunchRestore.everything.resolved(keepsWindows: false) == .everything)
    }

    @Test func theOldToggleTurnedOffStaysOff() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        try await store.setSetting("general.openLastRoot", "0")
        let settings = SettingsStore(noteStore: store)
        await settings.load()
        #expect(settings.launchRestore == .nothing)
    }

    @Test func folderDocumentLineModeHistoryAndPanelComeBack() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-ws-\(UUID().uuidString)").path
        let one = "\(base)/one", two = "\(base)/two"
        try FileManager.default.createDirectory(atPath: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: two, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let local = HostID.local.rawValue
        let body = (1...80).map { "Line \($0) of the plan." }.joined(separator: "\n\n") + "\n"
        try body.write(toFile: "\(two)/plan.md", atomically: true, encoding: .utf8)
        try "let x = 1\n".write(toFile: "\(one)/a.swift", atomically: true, encoding: .utf8)

        var workspace = Workspace()
        workspace.folders = [.init(host: local, path: one), .init(host: local, path: "\(base)/gone"), .init(host: local, path: two)]
        workspace.selectedFolder = 0
        workspace.document = .init(place: .init(host: local, path: "\(two)/plan.md"), line: 61, showsSource: true)
        workspace.back = [.init(host: local, path: "\(one)/a.swift")]
        workspace.showsNotesPanel = false

        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        defer { Task { await model.shutDown() } }
        await model.restore(workspace)
        #expect(model.explorer.tabs.map(\.path) == [one, two], "a folder that's gone is passed over")
        #expect(model.explorer.selectedTab?.path == one)
        #expect(model.showNotesPanel == false)
        await waitUntil { model.activeSession?.markdown?.mode == .source }
        let session = try #require(model.activeSession)
        #expect(session.path == "\(two)/plan.md")
        #expect(session.markdown?.mode == .source)
        #expect(model.history.canGoBack && model.history.recentBack() == [.init(hostID: .local, path: "\(one)/a.swift")])
        // Back to the line reading stopped at, at the top of the view (the view applies it once on screen).
        let controller = try #require(session.textController)
        let line61 = controller.lineIndex.contentRange(ofLine: 61).location
        await waitUntil { controller.pendingScroll?.location == line61 }
        #expect(controller.pendingScroll == NSRange(location: line61, length: 0))
        #expect(controller.pendingScrollAtTop && !controller.pendingScrollSelects, "resumed, not selected")

        // What's saved now is what was restored.
        let saved = model.currentWorkspace()
        #expect(saved.folders.map(\.path) == [one, two])
        #expect(saved.selectedFolder == 0)
        #expect(saved.document?.place.path == "\(two)/plan.md")
        #expect(saved.document?.showsSource == true)
        #expect(saved.back.map(\.path) == ["\(one)/a.swift"])
        #expect(saved.showsNotesPanel == false)
    }
}
