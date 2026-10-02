import Foundation

/// Environment checks evaluated once per run; gated tests skip when their resource is absent.
enum TestGates {
    static let tmux: Bool = {
        let path = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
        return path != nil
    }()

    /// Herdr's server is running on the default socket.
    static let herdr: Bool = {
        let socket = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/herdr/herdr.sock")
        return FileManager.default.fileExists(atPath: socket)
    }()

    static var remoteHost: String? {
        let value = ProcessInfo.processInfo.environment["GLOSS_REMOTE_HOST"] ?? ""
        return value.isEmpty ? nil : value
    }

    /// Runs a command and returns stdout; used for tmux setup and teardown on the private server.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
