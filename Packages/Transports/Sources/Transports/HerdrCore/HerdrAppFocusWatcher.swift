import Core
import Foundation
import Remote

/// Which agent Herdr.app (the window on top of herdr-core) has in focus. The core knows nothing about focus, so
/// this watches the app's `view.json`, which it rewrites whenever the selected space, tab or pane changes, and asks
/// `herdr-app status` for the focused agent then (and every few seconds, for a change inside a tab the file may
/// not record). Yields the agent's core address (`t7`, `studio/t3`) each time it changes.
public actor HerdrAppFocusWatcher {
    private let viewFile: String
    private let executable: String
    private var task: Task<Void, Never>?
    private let continuation: AsyncStream<String>.Continuation
    public nonisolated let focus: AsyncStream<String>

    public init(viewFile: String = HerdrAppFocusWatcher.defaultViewFile, executable: String) {
        self.viewFile = viewFile
        self.executable = executable
        (focus, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
    }

    public static var defaultViewFile: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/herdr-app/view.json")
    }

    /// Herdr.app's command-line entry, when it is installed.
    public static func locateApp() -> String? {
        let candidates = [(NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/herdr-app"), "/Applications/Herdr.app/Contents/MacOS/Herdr"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func start() {
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation.finish()
    }

    private func run() async {
        var lastModified: Date?
        var lastAgent: String?
        var sinceAsked = Duration.zero
        let tick: Duration = .milliseconds(400)
        while !Task.isCancelled {
            let modified = (try? FileManager.default.attributesOfItem(atPath: viewFile))?[.modificationDate] as? Date
            if modified != lastModified || sinceAsked >= .seconds(3) {
                lastModified = modified
                sinceAsked = .zero
                if let agent = await focusedAgent(), agent != lastAgent {
                    lastAgent = agent
                    continuation.yield(agent)
                }
            }
            try? await Task.sleep(for: tick)
            sinceAsked += tick
        }
    }

    /// `herdr-app status`'s `agent`: the focused agent's address, nil when the app isn't running or shows none.
    private func focusedAgent() async -> String? {
        guard let process = try? ChildProcess.launch(ChildProcessSpec(executable: executable, arguments: ["status"])) else { return nil }
        // A wedged app must not stop following for good, and a stopped watcher leaves no process behind.
        let output: Data? = await withTaskCancellationHandler {
            await withDeadline(.seconds(2)) {
                async let out = process.collectStdout()
                async let err = process.collectStderr()
                let code = try? await process.exitCode
                let output = await out
                _ = await err
                return code == 0 ? output : nil
            }
        } onCancel: {
            process.terminate()
        }
        guard let output else {
            process.terminate()
            return nil
        }
        return Self.agent(fromStatus: output)
    }

    static func agent(fromStatus data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agent = object["agent"] as? String, !agent.isEmpty else { return nil }
        return agent
    }
}
