import Foundation
import OSLog

/// Asks git which entries of a directory are ignored, one `git check-ignore` call per directory.
/// Outside a repository (exit 128) or when git is missing, nothing is ignored.
enum GitIgnoreService {
    nonisolated static let gitPath: String? = {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }()

    /// `entries` are names with a directory flag; directory patterns such as `build/` only match when git is told it is a directory.
    nonisolated static func ignoredNames(in directory: String, entries: [(name: String, isDirectory: Bool)]) async -> Set<String> {
        guard let gitPath, !entries.isEmpty else { return [] }
        let names = entries.map { $0.isDirectory ? $0.name + "/" : $0.name }
        let ignored = await Task.detached(priority: .utility) {
            run(gitPath: gitPath, directory: directory, names: names)
        }.value
        return Set(ignored.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
    }

    nonisolated private static func run(gitPath: String, directory: String, names: [String]) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", directory, "check-ignore", "--stdin", "-z"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.explorer.error("git check-ignore could not start: \(error, privacy: .public)")
            return []
        }
        var payload = Data()
        for name in names {
            payload.append(contentsOf: name.utf8)
            payload.append(0)
        }
        try? input.fileHandleForWriting.write(contentsOf: payload)
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }   // 1: nothing ignored, 128: not a repository
        let ignored = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return Set(ignored)
    }
}
