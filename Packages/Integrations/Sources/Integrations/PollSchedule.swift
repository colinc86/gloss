import Foundation

/// How long a resource poller waits before its next look: the usual interval after a good poll; doubling after
/// each failure up to five minutes, so an offline Mac or a refused key is not asked every ten seconds; and until
/// a spent rate limit resets.
struct PollSchedule {
    var interval: Duration
    private(set) var failures = 0
    static let longest: Duration = .seconds(300)

    init(interval: Duration) { self.interval = interval }

    mutating func succeeded() { failures = 0 }
    mutating func failed() { failures += 1 }

    func delay(rateLimitedUntil: Date?, now: Date = Date()) -> Duration {
        if let until = rateLimitedUntil, until > now {
            return max(interval, .milliseconds(Int64(until.timeIntervalSince(now) * 1000)))
        }
        guard failures > 0 else { return interval }
        var delay = interval
        for _ in 0..<min(failures, 8) { delay = delay * 2 }
        return min(delay, max(Self.longest, interval))
    }
}
