import Foundation
import Sparkle
import Testing
@testable import Gloss

/// Sparkle's requests carry the GitHub key while the repository is private; without one there is no check.
@MainActor
struct UpdaterDelegateTests {
    final class Key {
        var value: String?
    }

    func updater(_ delegate: UpdaterDelegate) -> SPUUpdater {
        SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: delegate)
    }

    @Test func checksCarryTheKeySavedRightNow() throws {
        let key = Key()
        let delegate = UpdaterDelegate { key.value }
        let updater = updater(delegate)

        #expect(throws: (any Error).self) { try delegate.updater(updater, mayPerform: .updates) }
        #expect(updater.httpHeaders == nil)

        key.value = "ghp_one"
        try delegate.updater(updater, mayPerform: .updatesInBackground)
        #expect(updater.httpHeaders?["Authorization"] == "Bearer ghp_one")
        #expect(updater.httpHeaders?["Accept"] == "application/vnd.github.raw")

        key.value = "ghp_two"
        try delegate.updater(updater, mayPerform: .updates)
        #expect(updater.httpHeaders?["Authorization"] == "Bearer ghp_two")

        key.value = nil
        do {
            try delegate.updater(updater, mayPerform: .updates)
            Issue.record("a check without a key should be refused")
        } catch {
            #expect((error as NSError).localizedDescription == UpdaterDelegate.missingKey)
        }
        #expect(updater.httpHeaders == nil)
    }

    @Test func theDownloadAsksForTheReleaseFilesBytesWithTheCurrentKeyOnlyFromGitHub() {
        let key = Key()
        key.value = "ghp_new"
        let delegate = UpdaterDelegate { key.value }
        func download(_ url: String) -> NSMutableURLRequest {
            let request = NSMutableURLRequest(url: URL(string: url)!)
            request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
            request.setValue("Bearer ghp_old", forHTTPHeaderField: "Authorization")
            delegate.updater(updater(delegate), willDownloadUpdate: SUAppcastItem.empty(), with: request)
            return request
        }
        let asset = download("https://api.github.com/repos/colinc86/gloss/releases/assets/1")
        #expect(asset.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(asset.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_new")
        #expect(download("https://example.com/Gloss.zip").value(forHTTPHeaderField: "Authorization") == nil)
        key.value = nil
        #expect(download("https://api.github.com/repos/colinc86/gloss/releases/assets/1").value(forHTTPHeaderField: "Authorization") == nil)
    }
}
