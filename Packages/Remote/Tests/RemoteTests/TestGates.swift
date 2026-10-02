import Foundation

/// Environment checks evaluated once per run; gated tests skip when their resource is absent.
enum TestGates {
    /// Remote Login is on and the key is in the agent.
    nonisolated(unsafe) static let loopback: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=accept-new", "localhost", "true"]
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
