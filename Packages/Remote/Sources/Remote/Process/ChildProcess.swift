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

    private let exitTask: Task<Int32, Never>
    private let state: Mutex<State>
    private let queue: DispatchQueue

    private struct State {
        var process: Process?
        var stdinHandle: FileHandle?
        var stdinClosed = false
    }

    public static func launch(_ spec: ChildProcessSpec) throws -> ChildProcess {
        try ChildProcess(spec)
    }

    private init(_ spec: ChildProcessSpec) throws {
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
        process.terminationHandler = { finished in
            exitBox.finish(finished.terminationStatus)
        }
        exitTask = Task { await exitBox.value }

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

    /// Resolves when the process exits.
    public var exitCode: Int32 {
        get async { await exitTask.value }
    }

    public var isRunning: Bool {
        state.withLock { $0.process?.isRunning ?? false }
    }

    /// Writes to stdin (only with `.pipe`). Blocking I/O on a utility task.
    public func write(_ data: Data) async throws {
        let handle: FileHandle? = state.withLock { $0.stdinClosed ? nil : $0.stdinHandle }
        guard let handle else { throw ChildProcessError.stdinClosed }
        let box = HandleBox(handle)
        try await Task.detached(priority: .utility) {
            try box.handle.write(contentsOf: data)
        }.value
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
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.kill()
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

/// Carries a `FileHandle` into a detached task; handles are safe to use from one task at a time.
private struct HandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
}

/// Bridges the termination handler to an awaitable value.
private final class ExitBox: Sendable {
    private let state = Mutex<(code: Int32?, waiters: [CheckedContinuation<Int32, Never>])>((nil, []))

    func finish(_ code: Int32) {
        let waiters: [CheckedContinuation<Int32, Never>] = state.withLock { state in
            state.code = code
            let pending = state.waiters
            state.waiters = []
            return pending
        }
        for waiter in waiters { waiter.resume(returning: code) }
    }

    var value: Int32 {
        get async {
            await withCheckedContinuation { continuation in
                let immediate: Int32? = state.withLock { state in
                    if let code = state.code { return code }
                    state.waiters.append(continuation)
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
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
