import Foundation
import Synchronization

/// What to launch. Everything the two packages run (ssh, git, tmux, herdr) goes through `ChildProcess`.
public struct ChildProcessSpec: Sendable {
    public enum StdinMode: Sendable {
        case null
        case pipe
    }

    public var executable: String
    public var arguments: [String]
    /// nil inherits the app's environment; otherwise these entries are added to it.
    public var extraEnvironment: [String: String]
    public var stdin: StdinMode
    public var workingDirectory: String?

    public init(executable: String, arguments: [String], extraEnvironment: [String: String] = [:], stdin: StdinMode = .null, workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.extraEnvironment = extraEnvironment
        self.stdin = stdin
        self.workingDirectory = workingDirectory
    }
}

public enum ChildProcessError: Error, Sendable, Equatable {
    case launchFailed(String)
    case stdinClosed
    case writeFailed(Int32)
}

/// A child process with its output as async streams and its exit code as an awaitable value.
/// Both pipes are always drained, so a chatty child never blocks on a full pipe.
public final class ChildProcess: Sendable {
    public let stdout: AsyncStream<Data>
    public let stderr: AsyncStream<Data>
    public let processIdentifier: Int32

    private let exitBox: ExitBox
    private let state: Mutex<State>
    private let queue: DispatchQueue

    /// A child that exits before reading its stdin would otherwise kill the app with SIGPIPE; ignoring it makes
    /// the write fail with EPIPE instead, which the callers handle. Done once, before the first launch.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    private struct State {
        var process: Process?
        var stdinHandle: FileHandle?
        var stdinClosed = false
    }

    public static func launch(_ spec: ChildProcessSpec) throws -> ChildProcess {
        try ChildProcess(spec)
    }

    private init(_ spec: ChildProcessSpec) throws {
        _ = Self.ignoreSIGPIPE
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        if !spec.extraEnvironment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(spec.extraEnvironment) { _, new in new }
        }
        if let directory = spec.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        var stdinHandle: FileHandle?
        switch spec.stdin {
        case .null:
            process.standardInput = FileHandle.nullDevice
        case .pipe:
            let inPipe = Pipe()
            process.standardInput = inPipe
            stdinHandle = inPipe.fileHandleForWriting
        }

        let queue = DispatchQueue(label: "com.cnc.Gloss.child.\(spec.executable.split(separator: "/").last ?? "")")
        self.queue = queue
        var stdoutContinuation: AsyncStream<Data>.Continuation?
        stdout = AsyncStream { stdoutContinuation = $0 }
        var stderrContinuation: AsyncStream<Data>.Continuation?
        stderr = AsyncStream { stderrContinuation = $0 }
        guard let stdoutContinuation, let stderrContinuation else { throw ChildProcessError.launchFailed("stream setup") }

        let exitBox = ExitBox()
        self.exitBox = exitBox
        process.terminationHandler = { finished in
            exitBox.finish(finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            stdoutContinuation.finish()
            stderrContinuation.finish()
            throw ChildProcessError.launchFailed("\(error)")
        }
        processIdentifier = process.processIdentifier
        state = Mutex(State(process: process, stdinHandle: stdinHandle))
        Self.pump(outPipe.fileHandleForReading, queue: queue, into: stdoutContinuation)
        Self.pump(errPipe.fileHandleForReading, queue: queue, into: stderrContinuation)
    }

    /// Reads a pipe through DispatchIO on the private queue; only the Sendable continuation is captured.
    private static func pump(_ handle: FileHandle, queue: DispatchQueue, into continuation: AsyncStream<Data>.Continuation) {
        let io = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            try? handle.close()
        }
        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: .max, queue: queue) { done, data, _ in
            if let data, !data.isEmpty {
                continuation.yield(Data(data))
            }
            if done {
                continuation.finish()
                io.close()
            }
        }
    }

    /// Resolves when the process exits. Throws `CancellationError` when the waiting task is cancelled,
    /// so timeouts built on task groups actually fire while the child is still running.
    public var exitCode: Int32 {
        get async throws { try await exitBox.value }
    }

    public var isRunning: Bool {
        state.withLock { $0.process?.isRunning ?? false }
    }

    /// Writes to stdin (only with `.pipe`) through DispatchIO on the private queue, so a slow reader parks the
    /// write instead of a cooperative-pool thread. Fails with EPIPE (not SIGPIPE) when the child is gone.
    public func write(_ data: Data) async throws {
        let handle: FileHandle? = state.withLock { $0.stdinClosed ? nil : $0.stdinHandle }
        guard let handle else { throw ChildProcessError.stdinClosed }
        let descriptor = handle.fileDescriptor
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchIO.write(toFileDescriptor: descriptor, data: bytes, runningHandlerOn: queue) { _, error in
                if error == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ChildProcessError.writeFailed(error))
                }
            }
        }
    }

    public func closeStdin() {
        let handle: FileHandle? = state.withLock { state in
            defer { state.stdinClosed = true }
            return state.stdinClosed ? nil : state.stdinHandle
        }
        try? handle?.close()
    }

    /// SIGTERM, then SIGKILL two seconds later if still running.
    public func terminate() {
        let process = state.withLock { $0.process }
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + 2) {
            // Not `self`: the owner may have dropped this object by then, and the follow-up must still fire.
            // The pid is reaped only by `Process`, so it cannot have been reused while the handler holds `process`.
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    public func kill() {
        let pid = state.withLock { $0.process?.isRunning == true ? $0.process?.processIdentifier : nil }
        if let pid { Darwin.kill(pid, SIGKILL) }
    }

    /// Collects all of stdout as data.
    public func collectStdout() async -> Data {
        var data = Data()
        for await chunk in stdout { data.append(chunk) }
        return data
    }

    public func collectStderr() async -> Data {
        var data = Data()
        for await chunk in stderr { data.append(chunk) }
        return data
    }
}

/// Bridges the termination handler to an awaitable, cancellable value. Each waiter is resumed exactly once:
/// by `finish`, or by cancellation, whichever removes it from the table first.
private final class ExitBox: Sendable {
    private struct Table {
        var code: Int32?
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Int32, any Error>] = [:]
    }

    private let state = Mutex(Table())

    func finish(_ code: Int32) {
        let waiters: [CheckedContinuation<Int32, any Error>] = state.withLock { table in
            table.code = code
            let pending = Array(table.waiters.values)
            table.waiters = [:]
            return pending
        }
        for waiter in waiters { waiter.resume(returning: code) }
    }

    var value: Int32 {
        get async throws {
            let id = state.withLock { table in
                table.nextID += 1
                return table.nextID
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let immediate: Int32? = state.withLock { table in
                        if let code = table.code { return code }
                        table.waiters[id] = continuation
                        return nil
                    }
                    if let immediate { continuation.resume(returning: immediate) }
                }
            } onCancel: {
                let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
                waiter?.resume(throwing: CancellationError())
            }
        }
    }
}

extension Data {
    init(_ dispatchData: DispatchData) {
        var out = Data(count: dispatchData.count)
        out.withUnsafeMutableBytes { buffer in
            dispatchData.copyBytes(to: buffer, count: dispatchData.count)
        }
        self = out
    }
}
