import Core
import Foundation
import Testing
@testable import Transports

struct TransportErrorMessageTests {
    @Test func herdrErrorsSaySentences() {
        #expect(HerdrError.timedOut.userMessage == "Herdr didn't answer in time")
        #expect(HerdrError.server(code: "pane_not_found", message: "No such pane").userMessage == "No such pane")
        #expect(!HerdrError.emptyReply.userMessage.contains("emptyReply"))
    }
}
