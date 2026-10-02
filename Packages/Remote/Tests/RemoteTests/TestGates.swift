import Foundation
import Remote

/// Environment checks evaluated once per run; gated tests skip when their resource is absent.
enum TestGates {
    /// Remote Login is on and the key is in the agent.
    nonisolated(unsafe) static let loopback: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // StrictHostKeyChecking=yes: the probe never writes to the developer's known_hosts; add localhost by hand once.
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=yes", "localhost", "true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    /// `GLOSS_REMOTE_HOST=<alias>` names the integration host.
    static var remoteHost: String? {
        let value = ProcessInfo.processInfo.environment["GLOSS_REMOTE_HOST"] ?? ""
        return value.isEmpty ? nil : value
    }

    static func temporaryControlDirectory() -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-test-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }
}

/// Loopback tests share one sshd; running them one at a time keeps them deterministic.
actor LoopbackSerializer {
    static let shared = LoopbackSerializer()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            busy = false
        }
    }
}

extension TestGates {
    static func serialized<T>(_ body: () async throws -> T) async throws -> T {
        await LoopbackSerializer.shared.acquire()
        defer { Task { await LoopbackSerializer.shared.release() } }
        return try await body()
    }

    /// A manager on a throwaway control directory. Every exit path, including a thrown `#require`, disconnects
    /// the masters before the directory is removed, so a failing test leaves no `ssh -N` behind.
    static func withManager<T>(serialized: Bool = true, _ body: (SSHConnectionManager, _ control: String) async throws -> T) async throws -> T {
        if serialized { await LoopbackSerializer.shared.acquire() }
        defer { if serialized { Task { await LoopbackSerializer.shared.release() } } }
        let control = temporaryControlDirectory()
        defer { try? FileManager.default.removeItem(atPath: control) }
        let manager = SSHConnectionManager(controlDirectory: control)
        do {
            let value = try await body(manager, control)
            await manager.disconnectAll()
            return value
        } catch {
            await manager.disconnectAll()
            throw error
        }
    }
}
