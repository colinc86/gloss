import Foundation

/// Command-line options the app accepts. See the `run-app` skill for the list.
nonisolated struct AppLaunchOptions: Equatable, Sendable, CustomStringConvertible {
    /// `--root <path>`: a directory to open as a root tab.
    var root: String?
    /// `--host <alias|local>`: the host the root and open paths belong to. Defaults to `local`.
    var host: String = "local"
    /// `--open <path>`: a file to open in the viewer.
    var open: String?
    /// `--reset-db`: use a throwaway database under `$TMPDIR` instead of the real one.
    var resetDatabase = false
    /// `--follow`: start with Herdr follow mode on, so scripted runs can watch it.
    var follow = false

    init() {}

    /// Parses `arguments` as passed by `CommandLine.arguments` (the executable path first).
    /// Unknown arguments, including the `-NS…` pairs Xcode injects, are ignored.
    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "--reset-db" {
                resetDatabase = true
            } else if argument == "--follow" {
                follow = true
            } else if let equals = argument.firstIndex(of: "="), argument.hasPrefix("--") {
                apply(key: String(argument[..<equals]), value: String(argument[argument.index(after: equals)...]))
            } else if argument.hasPrefix("--") {
                guard let value = iterator.next() else { break }
                apply(key: argument, value: value)
            }
        }
    }

    private mutating func apply(key: String, value: String) {
        switch key {
        case "--root": root = value
        case "--host": host = value
        case "--open": open = value
        default: break
        }
    }

    var description: String {
        var parts: [String] = ["host=\(host)"]
        if let root { parts.append("root=\(root)") }
        if let open { parts.append("open=\(open)") }
        if resetDatabase { parts.append("reset-db") }
        if follow { parts.append("follow") }
        return parts.joined(separator: " ")
    }
}
