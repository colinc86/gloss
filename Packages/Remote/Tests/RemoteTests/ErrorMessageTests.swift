import Core
import Foundation
import Testing
@testable import Remote

/// What a failed connection or file operation says to the reader: a sentence, not a case name.
struct RemoteErrorMessageTests {
    @Test func remoteErrorsSaySentences() {
        #expect(SSHError.timedOut.userMessage == "Timed out waiting for ssh")
        #expect(SSHError.authenticationFailed("me@box: Permission denied").userMessage.hasPrefix("Authentication failed"))
        #expect(SFTPStatus(code: .permissionDenied).userMessage == "Permission denied")
        #expect(SFTPStatus(code: .failure, message: "Disk quota exceeded").userMessage == "Disk quota exceeded", "the server's own words first")
        #expect(SFTPClientError.connectionLost.userMessage == "The connection to the host was lost")
        #expect(SFTPCodecError.truncated.userMessage == "The host's file service sent a reply that was cut short")
        #expect(ChildProcessError.writeFailed(EPIPE).userMessage == "Writing to a helper program failed: Broken pipe")
    }
}
