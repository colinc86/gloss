import Foundation
import Synchronization

/// Runs `body` with a time limit. Returns its value, or nil when the deadline passes first.
/// Unlike a task group this never waits for the loser: a `body` that cannot observe cancellation keeps running
/// on its own, so use it only for work that ends by itself (a pipe draining, a process exiting, a disconnect).
public func withDeadline<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async -> T) async -> T? {
    let settled = Mutex(false)
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let resume: @Sendable (T?) -> Void = { value in
            let first = settled.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { continuation.resume(returning: value) }
        }
        Task { resume(await body()) }
        Task {
            try? await Task.sleep(for: limit)
            resume(nil)
        }
    }
}
