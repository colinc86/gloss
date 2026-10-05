import Foundation
import Observation
import Sparkle

/// Updates through Sparkle, from Gloss's releases on GitHub: its standard dialog shows the release notes and
/// offers Install Update, Remind Me Later and Skip This Version; installing swaps the app in place and relaunches.
///
/// While the repository is private, the feed (`SUFeedURL`, `appcast.xml` on raw.githubusercontent.com) and the
/// release files are read with the GitHub key from Settings › Integrations; without one there are no updates. When the repository
/// goes public, the feed moves to a public URL and the key goes (see the memory note on going public).
///
/// Debug builds never start the updater: the copy in DerivedData must not be replaced by a release.
@MainActor @Observable
final class UpdaterService {
    /// False in debug builds: no menu item, no Settings section.
    let isAvailable: Bool
    private(set) var canCheckForUpdates = false
    private(set) var lastCheck: Date?
    /// Sparkle keeps this in user defaults itself.
    var automaticallyChecks = true {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// `token` is read at every check, so saving or removing the GitHub key needs no wiring.
    init(enabled: Bool, token: @escaping @MainActor () -> String?) {
        isAvailable = enabled
        delegate = UpdaterDelegate(token: token)
        controller = enabled ? SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil) : nil
    }

    func start() {
        guard let controller else { return }
        controller.startUpdater()
        let updater = controller.updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        // Sparkle changes these on the main thread.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastCheck = updater.lastUpdateCheckDate }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecks = updater.automaticallyChecksForUpdates }
            },
        ]
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Puts the GitHub key on Sparkle's requests, and stops a check when there is none: a check the reader asked for
/// says why, a scheduled one stays quiet.
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    static let missingKey = "Updates need GitHub connected in Settings › Integrations while Gloss's repository is private."

    private let token: () -> String?

    init(token: @escaping @MainActor () -> String?) {
        self.token = token
    }

    /// Sent with every Sparkle request: the feed on raw.githubusercontent.com, which serves a private repository's
    /// file to a key that can read it. Sparkle sets the feed's `Accept` itself (so the contents API, which picks
    /// its answer by `Accept`, can't serve the feed); the download's is set below.
    nonisolated static func headers(token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)"]
    }

    /// Sparkle reads `httpHeaders` after this returns, so the key is the one saved right now.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard let token = token() else {
            updater.httpHeaders = nil
            throw NSError(domain: "com.cnc.Gloss.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: Self.missingKey])
        }
        updater.httpHeaders = Self.headers(token: token)
    }

    /// The release file is a private release asset: its API URL answers with the bytes (a redirect to storage,
    /// which URLSession follows without the key) only when asked for an octet stream. The key is read again here,
    /// so one removed since the check isn't used, and it goes only to GitHub's API, whatever the appcast names.
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        if request.url?.host == "api.github.com", let token = token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
    }
}
