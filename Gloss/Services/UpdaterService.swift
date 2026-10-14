import Foundation
import Observation
import Sparkle

/// Updates through Sparkle, from Gloss's releases on GitHub: its standard dialog shows the release notes and
/// offers Install Update, Remind Me Later and Skip This Version; installing swaps the app in place and relaunches.
///
/// The feed (`SUFeedURL`) is `appcast.xml` on raw.githubusercontent.com and the release files are public release
/// assets, so updates need no account or key.
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

    init(enabled: Bool) {
        isAvailable = enabled
        delegate = UpdaterDelegate()
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

/// Downloads ask for the release file's bytes. Releases published while the repository was private list the asset's
/// API URL, which answers with the bytes (a redirect to storage) only when asked for an octet stream; newer ones list
/// its download URL, which ignores `Accept`. No request carries a key.
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
    }
}
