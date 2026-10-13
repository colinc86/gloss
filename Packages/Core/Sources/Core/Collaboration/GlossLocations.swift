import Foundation

/// Where reviews live: plain iCloud Drive, which a non-sandboxed Developer ID app reaches without an iCloud
/// entitlement.
public enum GlossLocations {
    /// The folder the owner's reviews are created in, inside iCloud Drive.
    public static let reviewsFolderName = "Gloss"

    /// `~/Library/Mobile Documents/com~apple~CloudDocs` when iCloud Drive is on; nil otherwise.
    public static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }

    /// Signed in to iCloud. Needs no entitlement.
    public static var isSignedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    /// iCloud Drive/Gloss, created on first use.
    public static func reviewsFolder() throws -> URL {
        guard let drive = iCloudDrive else { throw GlossPackageError.notAPackage("iCloud Drive isn't available") }
        let folder = drive.appending(path: reviewsFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Every `.gloss` package in iCloud Drive/Gloss and at the top of iCloud Drive (where accepted invitations
    /// land), sorted by name.
    public static func findReviews() -> [URL] {
        guard let drive = iCloudDrive else { return [] }
        return reviews(in: [drive, drive.appending(path: reviewsFolderName, directoryHint: .isDirectory)])
    }

    /// The `.gloss` packages directly inside `folders`, sorted by name. Evicted packages show up as their iCloud
    /// placeholder (`.Name.gloss.icloud`) and are listed under their real name.
    public static func reviews(in folders: [URL]) -> [URL] {
        var found: Set<URL> = []
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names {
                var real = name
                if name.hasPrefix("."), name.hasSuffix(".icloud") { real = String(name.dropFirst().dropLast(".icloud".count)) }
                guard (real as NSString).pathExtension == GlossFormat.fileExtension else { continue }
                found.insert(folder.appending(path: real, directoryHint: .isDirectory))
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// "Review of README.md", made safe for a file name, without the extension.
    public static func defaultFileName(for title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? String(cleaned.drop { $0 == "." }) : cleaned
        return "Review of " + (trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(180)))
    }

    /// `name.gloss` in `folder`, or `name 2.gloss`, `name 3.gloss`… when taken.
    public static func availableURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appending(path: name + "." + GlossFormat.fileExtension, directoryHint: .isDirectory)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path)
                || FileManager.default.fileExists(atPath: folder.appending(path: "." + candidate.lastPathComponent + ".icloud").path) {
            candidate = folder.appending(path: "\(name) \(number).\(GlossFormat.fileExtension)", directoryHint: .isDirectory)
            number += 1
        }
        return candidate
    }
}
