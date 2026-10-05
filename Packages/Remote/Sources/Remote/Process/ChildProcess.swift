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
    /// Starts the child as the leader of its own process group, so `kill()` also reaches what it spawned (a
    /// `Match exec` shell under `ssh -G`).
    public var newProcessGroup: Bool

    public init(executable: String, arguments: [String], extraEnvironment: [String: String] = [:], stdin: StdinMode = .null, workingDirectory: String? = nil, newProcessGroup: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.extraEnvironment = extraEnvironment
        self.stdin = stdin
        self.workingDirectory = workingDirectory
        self.newProcessGroup = newProcessGroup
    }
}

public enum ChildProcessError: Error, Sendable, Equatable {
    case launchFailed(String)
    case stdinClosed
    case writeFailed(Int32)
}

/// A child process with its output as async streams and its exit code as an awaitable value.
/// Both pipes are always drained, so a chatty child never blocks on a full pipe.
///
/// Children are spawned with `posix_spawn` and *disclaim responsibility*: each child is its own "responsible
/// process" for macOS attribution purposes. Without that, a key agent such as 1Password attributes every `ssh`
/// request to this app, asks for approval once per build signature, and silently refuses after a prompt dies
/// (for example when the app is stopped in Xcode). Attributed to `/usr/bin/ssh` itself, one approval holds across
/// every rebuild of the app.
public final class ChildProcess: Sendable {
    public let stdout: AsyncStream<Data>
    public let stderr: AsyncStream<Data>
    public let processIdentifier: Int32

    private let exitBox: ExitBox
    private let state: StateBox
    private let queue: DispatchQueue
    private let exitSource: any DispatchSourceProcess

    /// A child that exits before reading its stdin would otherwise kill the app with SIGPIPE; ignoring it makes
    /// the write fail with EPIPE instead, which the callers handle. Done once, before the first launch.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    private struct State {
        var running = true
        var stdinHandle: FileHandle?
        var stdinClosed = false
    }

    /// Reference wrapper so the exit handler and the SIGKILL follow-up can share the state (`Mutex` cannot be copied).
    private final class StateBox: Sendable {
        let mutex: Mutex<State>
        init(_ state: State) { mutex = Mutex(state) }
        func withLock<T: Sendable>(_ body: (inout State) throws -> T) rethrows -> T { try mutex.withLock { try body(&$0) } }
    }

    public static func launch(_ spec: ChildProcessSpec) throws -> ChildProcess {
        try ChildProcess(spec)
    }

    private init(_ spec: ChildProcessSpec) throws {
        _ = Self.ignoreSIGPIPE
        let queue = DispatchQueue(label: "com.cnc.Gloss.child.\(spec.executable.split(separator: "/").last ?? "")")
        self.queue = queue
        var stdoutContinuation: AsyncStream<Data>.Continuation?
        stdout = AsyncStream { stdoutContinuation = $0 }
        var stderrContinuation: AsyncStream<Data>.Continuation?
        stderr = AsyncStream { stderrContinuation = $0 }
        guard let stdoutContinuation, let stderrContinuation else { throw ChildProcessError.launchFailed("stream setup") }

        // Pipes: the child's ends are passed through dup2; the parent's ends are close-on-exec.
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1], inPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw ChildProcessError.launchFailed("pipe: \(errno)") }
        if spec.stdin == .pipe { guard pipe(&inPipe) == 0 else { throw ChildProcessError.launchFailed("pipe: \(errno)") } }
        for fd in [outPipe[0], errPipe[0], inPipe[1]] where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if spec.stdin == .pipe {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let directory = spec.workingDirectory { posix_spawn_file_actions_addchdir(&actions, directory) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every descriptor the child did not get through dup2 above, and give it default signal handling.
        // Every catchable signal, not just SIGPIPE: the app ignores SIGTERM/SIGINT/SIGHUP to route them into a clean
        // quit, and an inherited SIG_IGN would make `terminate()` a no-op for ssh and every other child.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        // The signal mask is inherited too, and this runs on a concurrency worker thread whose mask blocks
        // SIGTERM: without an empty mask every child ignored `terminate()` until the SIGKILL two seconds later.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if spec.newProcessGroup {
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        Self.disclaimResponsibility(&attributes)

        let environment = ProcessInfo.processInfo.environment.merging(spec.extraEnvironment) { _, new in new }
        let argv = [spec.executable] + spec.arguments
        var pid: pid_t = 0
        let status = Self.withCStrings(argv) { argvPointer in
            Self.withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envPointer in
                posix_spawn(&pid, spec.executable, &actions, &attributes, argvPointer, envPointer)
            }
        }
        // The child's ends are the child's now; keep only the parent's ends.
        close(outPipe[1])
        close(errPipe[1])
        if inPipe[0] >= 0 { close(inPipe[0]) }
        guard status == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            if inPipe[1] >= 0 { close(inPipe[1]) }
            stdoutContinuation.finish()
            stderrContinuation.finish()
            throw ChildProcessError.launchFailed("\(spec.executable): \(String(cString: strerror(status)))")
        }

        processIdentifier = pid
        let stdinHandle = inPipe[1] >= 0 ? FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: true) : nil
        let state = StateBox(State(stdinHandle: stdinHandle))
        self.state = state
        let exitBox = ExitBox()
        self.exitBox = exitBox
        // Exit is observed through a dispatch source; the status is reaped there so the pid is never reused
        // before the handlers have run.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource = source
        source.setEventHandler {
            var rawStatus: Int32 = 0
            while waitpid(pid, &rawStatus, 0) < 0 && errno == EINTR {}
            let code: Int32
            if (rawStatus & 0x7f) == 0 {   // WIFEXITED
                code = (rawStatus >> 8) & 0xff
            } else {   // signalled: report the signal number, as Foundation's Process does
                code = rawStatus & 0x7f
            }
            state.withLock { $0.running = false }
            exitBox.finish(code)
            source.cancel()
        }
        source.resume()
        Self.pump(FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true), queue: queue, into: stdoutContinuation)
        Self.pump(FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true), queue: queue, into: stderrContinuation)
    }

    /// `responsibility_spawnattrs_setdisclaim` is not in the public headers but has shipped in libSystem since
    /// macOS 10.14 and is what browsers use for their helpers. Absent symbol: children stay attributed to the app.
    private static let disclaimFunction: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32).self)
    }()

    private static func disclaimResponsibility(_ attributes: inout posix_spawnattr_t?) {
        _ = disclaimFunction?(&attributes, 1)
    }

    private static func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
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
        state.withLock { $0.running }
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
        guard isRunning else { return }
        let pid = processIdentifier
        let state = state
        Darwin.kill(pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + 2) {
            // Not `self`: the owner may have dropped this object by then, and the follow-up must still fire.
            // The pid is reaped only by this object's exit source, so it cannot have been reused while `running`.
            if state.withLock({ $0.running }) { Darwin.kill(pid, SIGKILL) }
        }
    }

    public func kill() {
        if isRunning { Darwin.kill(processIdentifier, SIGKILL) }
    }

    /// SIGKILL to the child's whole process group; only for a child started with `newProcessGroup`.
    public func killGroup() {
        if isRunning { Darwin.kill(-processIdentifier, SIGKILL) }
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
