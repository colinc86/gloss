import Core
import Foundation

/// What the explorer reacts to: the focused agent pane's directory and status.
public struct FollowEvent: Sendable, Equatable {
    public var hostID: HostID
    public var paneID: String
    public var path: String?
    public var agent: String?
    public var status: String?

    public init(hostID: HostID, paneID: String, path: String?, agent: String?, status: String?) {
        self.hostID = hostID
        self.paneID = paneID
        self.path = path
        self.agent = agent
        self.status = status
    }
}

/// Follows one Herdr endpoint: a focus event is answered with `pane.get` (focus frames carry no cwd), status
/// changes stream through, and the subscription is rebuilt whenever a new agent pane appears or events were lost.
/// Single use: `stop()` finishes `events`; make a new service to follow again.
public actor HerdrFollowService {
    public nonisolated let events: AsyncStream<FollowEvent>
    private let continuation: AsyncStream<FollowEvent>.Continuation
    private let hostID: HostID
    private let client: HerdrClient
    private var task: Task<Void, Never>?

    public init(hostID: HostID, socketPath: String) {
        self.hostID = hostID
        self.client = HerdrClient(socketPath: socketPath)
        var continuation: AsyncStream<FollowEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                let completed = await self.runOnce()
                if Task.isCancelled { return }
                attempt = completed ? 0 : attempt + 1
                let delay = [1.0, 2.0, 4.0, 8.0, 15.0][min(attempt, 4)]
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation.finish()
    }

    /// One subscription lifetime. Returns true when the server closed it normally (no backoff needed).
    private func runOnce() async -> Bool {
        let agents = (try? await client.agentList()) ?? []
        for agent in agents where agent.agent != nil {
            continuation.yield(FollowEvent(hostID: hostID, paneID: agent.paneID, path: agent.currentDirectory, agent: agent.agent, status: agent.agentStatus))
        }
        var subscriptions: [[String: String]] = [["type": "pane.focused"], ["type": "pane.closed"], ["type": "pane.created"], ["type": "pane.agent_detected"]]
        subscriptions += agents.map { ["type": "pane.agent_status_changed", "pane_id": $0.paneID] }
        do {
            for try await event in client.subscribe(subscriptions) {
                switch event.event {
                case "pane_focused":
                    guard let paneID = event.paneID, let pane = try? await client.paneGet(paneID) else { continue }
                    continuation.yield(FollowEvent(hostID: hostID, paneID: paneID, path: pane.currentDirectory, agent: pane.agent, status: pane.agentStatus))
                case "pane_agent_status_changed":
                    guard let paneID = event.paneID else { continue }
                    continuation.yield(FollowEvent(hostID: hostID, paneID: paneID, path: nil, agent: event.agent, status: event.agentStatus))
                case "pane_agent_detected", "pane_created":
                    return true   // resubscribe so the new pane's status events are included
                default:
                    continue
                }
            }
            return true
        } catch HerdrError.eventsLost {
            return true
        } catch {
            return false
        }
    }
}
