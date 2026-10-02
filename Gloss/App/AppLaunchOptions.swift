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

    init() {}

    /// Parses `arguments` as passed by `CommandLine.arguments` (the executable path first).
    /// Unknown arguments, including the `-NS…` pairs Xcode injects, are ignored.
    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--root":
                root = iterator.next()
            case "--host":
                host = iterator.next() ?? "local"
            case "--open":
                open = iterator.next()
            case "--reset-db":
                resetDatabase = true
            default:
                if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                    let key = String(argument[..<equals])
                    let value = String(argument[argument.index(after: equals)...])
                    switch key {
                    case "--root": root = value
                    case "--host": host = value
                    case "--open": open = value
                    default: break
                    }
                }
            }
        }
    }

    var description: String {
        var parts: [String] = ["host=\(host)"]
        if let root { parts.append("root=\(root)") }
        if let open { parts.append("open=\(open)") }
        if resetDatabase { parts.append("reset-db") }
        return parts.joined(separator: " ")
    }
}
