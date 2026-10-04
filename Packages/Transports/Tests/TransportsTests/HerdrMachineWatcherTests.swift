import Core
import Foundation
import Remote
import Testing
@testable import Transports

struct HerdrMachineWatcherTests {
    private func makeStateDirectory() throws -> String {
        let directory = NSTemporaryDirectory() + "gloss-herdr-state-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"ssh":[{"id":"0533c7e71e81fa46a658ff015042cbb7","label":"asus box","target":"asus","session":"default","enabled":true}]}"#.utf8)
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("endpoints.json"))
        return directory
    }

    private func writeSelection(_ json: String, in directory: String) throws {
        try Data(json.utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("endpoint-selection.json"), options: .atomic)
    }

    @Test func readsLocalRemoteAndUnknownSelections() throws {
        let directory = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(HerdrMachineSelection.read(stateDirectory: directory) == nil, "no selection file yet")
        try writeSelection(#"{"version":1,"selected_profile":null}"#, in: directory)
        #expect(HerdrMachineSelection.read(stateDirectory: directory) == .local)
        try writeSelection(#"{"version":1,"selected_profile":{"ssh":"0533c7e71e81fa46a658ff015042cbb7"}}"#, in: directory)
        #expect(HerdrMachineSelection.read(stateDirectory: directory) == .remote(target: "asus", label: "asus box"))
        try writeSelection(#"{"version":1,"selected_profile":"ssh:0533c7e71e81fa46a658ff015042cbb7"}"#, in: directory)
        #expect(HerdrMachineSelection.read(stateDirectory: directory) == .remote(target: "asus", label: "asus box"), "the string spelling matches too")
        try writeSelection(#"{"version":1,"selected_profile":{"ssh":"ffffffffffffffffffffffffffffffff"}}"#, in: directory)
        if case .unknown = HerdrMachineSelection.read(stateDirectory: directory) {} else { Issue.record("an id missing from endpoints.json is unknown") }
    }

    @Test func streamsChangesAndFinishesOnStop() async throws {
        let directory = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try writeSelection(#"{"version":1,"selected_profile":null}"#, in: directory)
        let watcher = HerdrMachineWatcher(stateDirectory: directory)
        await watcher.start()
        let first = await next(from: watcher.events, within: .seconds(5))
        #expect(first == .local, "the current selection is emitted first")
        try writeSelection(#"{"version":1,"selected_profile":{"ssh":"0533c7e71e81fa46a658ff015042cbb7"}}"#, in: directory)
        let second = await next(from: watcher.events, within: .seconds(10))
        #expect(second == .remote(target: "asus", label: "asus box"))
        await watcher.stop()
        let end = await next(from: watcher.events, within: .seconds(5))
        #expect(end == nil, "stop finishes the stream")
    }
}

/// The next element, or nil at the deadline or when the stream finished. An `AsyncStream` keeps its position
/// across iterators, so each call picks up where the previous one stopped.
private func next(from stream: AsyncStream<HerdrMachineSelection>, within limit: Duration) async -> HerdrMachineSelection? {
    await withDeadline(limit) { () -> HerdrMachineSelection? in
        for await element in stream { return element }
        return nil
    } ?? nil
}
