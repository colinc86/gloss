import Foundation
import Testing
@testable import Core

struct ErrorTextTests {
    private enum Plain: Error { case refused(String) }

    @Test func peopleSeeAnErrorsMessageNotItsCaseName() {
        #expect(FileSystemError.notFound("/p/a.md").userMessage == "The file or folder is missing: /p/a.md")
        #expect("\(FileSystemError.notFound("/p/a.md"))".contains("notFound"), "what plain interpolation showed")
        #expect(Plain.refused("busy").userMessage == "refused(\"busy\")", "an error with no message keeps its description")
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
        #expect(!cocoa.userMessage.contains("Domain="), "a Cocoa error reads as a sentence: \(cocoa.userMessage)")
    }
}
