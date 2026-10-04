import Core
import Foundation

/// Which Herdr server the local Herdr client is showing: this Mac, or one of its saved SSH machines.
/// The socket API has no notion of machines (each server only knows its own panes), so this is read from the
/// client's state files instead: `endpoint-selection.json` names the selected profile and `endpoints.json`
/// maps profile ids to their ssh targets, which are the same aliases the app's hosts use.
public enum HerdrMachineSelection: Sendable, Equatable {
    case local
    /// `target` is the ssh destination Herdr connects to (an alias from `~/.ssh/config`); `label` is Herdr's display name.
    case remote(target: String, label: String)
    /// A selection the endpoint catalogue does not list (stale state, or a profile kind we do not know).
    case unknown(String)

    /// Where the client keeps its state: `$XDG_STATE_HOME/herdr/client`, else `~/.local/state/herdr/client`.
    public static func defaultStateDirectory() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state")
        return (base as NSString).appendingPathComponent("herdr/client")
    }

    /// Reads the current selection, or nil when the client has never written one (an older Herdr, or none installed).
    public static func read(stateDirectory: String = defaultStateDirectory()) -> HerdrMachineSelection? {
        let selectionURL = URL(fileURLWithPath: stateDirectory).appendingPathComponent("endpoint-selection.json")
        guard let data = try? Data(contentsOf: selectionURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let selected = object["selected_profile"], !(selected is NSNull) else { return .local }
        let endpointsURL = URL(fileURLWithPath: stateDirectory).appendingPathComponent("endpoints.json")
        let endpoints = (try? Data(contentsOf: endpointsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["ssh"] as? [[String: Any]] } ?? []
        // The profile is serialised by Herdr as an enum (`{"ssh": "<id>"}` or `"ssh:<id>"`); matching the id
        // as a substring survives either spelling.
        let description = (try? JSONSerialization.data(withJSONObject: selected, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(selected)"
        for endpoint in endpoints {
            guard let id = endpoint["id"] as? String, !id.isEmpty, description.contains(id) else { continue }
            let target = endpoint["target"] as? String ?? ""
            let label = endpoint["label"] as? String ?? target
            return target.isEmpty ? .unknown(description) : .remote(target: target, label: label)
        }
        return .unknown(description)
    }
}

/// Streams the selected Herdr machine as the client switches. Single use: `stop()` finishes `events`.
public actor HerdrMachineWatcher {
    public nonisolated let events: AsyncStream<HerdrMachineSelection>
    private let continuation: AsyncStream<HerdrMachineSelection>.Continuation
    private let stateDirectory: String
    private var task: Task<Void, Never>?
    private var last: HerdrMachineSelection?

    public init(stateDirectory: String = HerdrMachineSelection.defaultStateDirectory()) {
        self.stateDirectory = stateDirectory
        var continuation: AsyncStream<HerdrMachineSelection>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Emits the current selection, then every change. FSEvents carries the changes; a slow poll covers a
    /// replaced directory or a missed event, since the file is a few dozen bytes.
    public func start() {
        guard task == nil else { return }
        check()
        task = Task { [weak self] in
            let directory = self?.stateDirectory ?? ""
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in FSEventsWatcher.events(forPaths: [directory], latency: 0.2) {
                        if Task.isCancelled { return }
                        await self?.check()
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        await self?.check()
                    }
                }
                await group.next()
                group.cancelAll()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation.finish()
    }

    private func check() {
        guard let selection = HerdrMachineSelection.read(stateDirectory: stateDirectory), selection != last else { return }
        last = selection
        continuation.yield(selection)
    }
}
