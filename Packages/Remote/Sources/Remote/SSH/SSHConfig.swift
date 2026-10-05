import Foundation

/// A concrete `Host` alias from ssh config, usable as a destination.
public struct SSHConfigHost: Sendable, Hashable, Identifiable {
    public var alias: String
    public var sourceFile: String

    public init(alias: String, sourceFile: String) {
        self.alias = alias
        self.sourceFile = sourceFile
    }

    public var id: String { alias }
}

/// Enumerates destinations from `~/.ssh/config`. Resolution of hostname, user, and port is left to `ssh -G`
/// so `Match`, `ProxyJump`, and canonicalization behave exactly as in the shell.
public enum SSHConfig {
    public static let maximumIncludeDepth = 8

    public static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    }

    public static func hostAliases(from path: String = defaultPath) -> [SSHConfigHost] {
        var seen: Set<String> = []
        var visited: Set<String> = []
        var result: [SSHConfigHost] = []
        collect(from: path, depth: 0, seen: &seen, visited: &visited, into: &result)
        return result
    }

    private static func collect(from path: String, depth: Int, seen: inout Set<String>, visited: inout Set<String>, into result: inout [SSHConfigHost]) {
        // Each file is read once: a config that includes itself (or a glob over its own folder) otherwise fans out
        // to N^depth reads, on the main thread.
        let real = (path as NSString).resolvingSymlinksInPath
        guard depth <= maximumIncludeDepth, visited.insert(real).inserted, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (keyword, value) = split(line)
            switch keyword.lowercased() {
            case "host":
                for pattern in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    let alias = String(pattern)
                    guard !alias.contains("*"), !alias.contains("?"), !alias.hasPrefix("!"), seen.insert(alias).inserted else { continue }
                    result.append(SSHConfigHost(alias: alias, sourceFile: path))
                }
            case "include":
                for pattern in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    var expanded = String(pattern)
                    if expanded.hasPrefix("~") { expanded = NSHomeDirectory() + expanded.dropFirst() }
                    if !expanded.hasPrefix("/") { expanded = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/" + expanded) }
                    for file in glob(expanded) {
                        collect(from: file, depth: depth + 1, seen: &seen, visited: &visited, into: &result)
                    }
                }
            default:
                continue
            }
        }
    }

    /// `Keyword value`, `Keyword=value`, with optional quotes around the value.
    static func split(_ line: String) -> (String, String) {
        var keyword = ""
        var rest = Substring(line)
        if let index = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) {
            keyword = String(line[..<index])
            rest = line[index...]
        } else {
            return (line, "")
        }
        var value = rest.trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        return (keyword, value)
    }

    static func glob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_matchc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
    }

    /// Display values resolved by ssh itself.
    public struct Resolved: Sendable, Equatable {
        public var hostName: String
        /// The agent socket ssh will ask for keys (`IdentityAgent`), when the config sets one.
        public var identityAgent: String?
        public var user: String?
        public var port: Int

        public init(hostName: String, user: String?, port: Int) {
            self.hostName = hostName
            self.user = user
            self.port = port
        }
    }

    /// `options` are the host's own `-o` arguments (a host added in Settings), so the answer matches what a
    /// connection would use. A `Match exec` that never returns is cut off after `timeout`.
    public static func resolve(_ alias: String, options: [String] = [], sshPath: String = "/usr/bin/ssh", timeout: Duration = .seconds(5)) async -> Resolved? {
        guard let process = try? ChildProcess.launch(ChildProcessSpec(executable: sshPath, arguments: ["-G"] + options + ["--", alias])) else { return nil }
        guard let stdout = await withDeadline(timeout, { await process.collectStdout() }) else {
            process.kill()
            _ = try? await process.exitCode
            return nil
        }
        let output = String(decoding: stdout, as: UTF8.self)
        guard (try? await process.exitCode) == 0 else { return nil }
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let hostName = values["hostname"] else { return nil }
        var resolved = Resolved(hostName: hostName, user: values["user"], port: Int(values["port"] ?? "22") ?? 22)
        if let agent = values["identityagent"], agent != "none" { resolved.identityAgent = agent }
        return resolved
    }
}
