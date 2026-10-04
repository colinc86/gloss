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
    /// `--appearance dark|light`: force one appearance for this run, to check both without changing System Settings.
    var appearance: String?
    /// The app is the host of a unit-test run. It then uses a throwaway database and skips `start()`: reopening
    /// the last root could connect a remote host (whose master the test runner then orphaned by killing the
    /// process), and the MCP server would take the real port from a running copy of the app.
    var isTestHost = false

    init() {}

    /// Arguments plus the environment Xcode sets for a hosted test run.
    init(arguments: [String], environment: [String: String]) {
        self.init(arguments: arguments)
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            isTestHost = true
            resetDatabase = true
        }
    }

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
        case "--appearance": appearance = ["dark", "light"].contains(value.lowercased()) ? value.lowercased() : nil
        default: break
        }
    }

    var description: String {
        var parts: [String] = ["host=\(host)"]
        if let root { parts.append("root=\(root)") }
        if let open { parts.append("open=\(open)") }
        if resetDatabase { parts.append("reset-db") }
        if follow { parts.append("follow") }
        if let appearance { parts.append("appearance=\(appearance)") }
        if isTestHost { parts.append("test-host") }
        return parts.joined(separator: " ")
    }
}
