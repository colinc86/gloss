import Foundation
import OSLog
import Remote

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
        let ignored = await run(gitPath: gitPath, directory: directory, names: names)
        return Set(ignored.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
    }

    /// Feeds the names to `git check-ignore --stdin -z` without blocking a thread on the pipes.
    @concurrent nonisolated private static func run(gitPath: String, directory: String, names: [String]) async -> Set<String> {
        let spec = ChildProcessSpec(executable: gitPath, arguments: ["-C", directory, "check-ignore", "--stdin", "-z"], stdin: .pipe)
        let process: ChildProcess
        do {
            process = try ChildProcess.launch(spec)
        } catch {
            Log.explorer.error("git check-ignore could not start: \(error, privacy: .public)")
            return []
        }
        var payload = Data()
        for name in names {
            payload.append(contentsOf: name.utf8)
            payload.append(0)
        }
        // Drain stdout concurrently with the write so a long listing cannot deadlock on a full pipe.
        async let output = process.collectStdout()
        try? await process.write(payload)
        process.closeStdin()
        let data = await output
        guard (try? await process.exitCode) == 0 else { return [] }   // 1: nothing ignored, 128: not a repository
        let ignored = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return Set(ignored)
    }
}
