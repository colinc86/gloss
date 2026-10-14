import Foundation
import Sparkle
import Testing
@testable import Gloss

/// Updates come from the public repository: downloads ask for the release file's bytes and never carry a key.
@MainActor
struct UpdaterDelegateTests {
    @Test func theDownloadAsksForTheReleaseFilesBytesWithoutAKey() {
        let delegate = UpdaterDelegate()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: delegate)
        func download(_ url: String) -> NSMutableURLRequest {
            let request = NSMutableURLRequest(url: URL(string: url)!)
            request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
            request.setValue("Bearer ghp_old", forHTTPHeaderField: "Authorization")
            delegate.updater(updater, willDownloadUpdate: SUAppcastItem.empty(), with: request)
            return request
        }
        for url in ["https://api.github.com/repos/o/r/releases/assets/1", "https://github.com/o/r/releases/download/v1.0.0/Gloss-1.0.0.zip"] {
            let request = download(url)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }
}
