import Foundation

/// Quoting for the exec channel: everything goes to `sh -c '<script>'`, so scripts are single-quoted
/// and embedded single quotes become `'\''`.
public enum ShellQuote {
    public static func single(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Joins arguments into one command line with each argument single-quoted.
    public static func command(_ arguments: [String]) -> String {
        arguments.map(single).joined(separator: " ")
    }
}
