import Foundation
import Testing
@testable import Core

struct DeliveryErrorTests {
    @Test func interpolatesAsPlainSentences() {
        #expect("\(DeliveryError.targetUnavailable("host is not connected"))" == "The agent is not reachable (host is not connected)")
        #expect("\(DeliveryError.agentBlocked("The agent is waiting on a permission prompt"))" == "The agent is waiting on a permission prompt")
        #expect("\(DeliveryError.failed(""))" == "Delivery failed")
        #expect("\(DeliveryError.packetTooLarge(limit: 1_048_576))".hasPrefix("The notes are too long for this transport"))
        let error: any Error = DeliveryError.failed("pane closed")
        #expect(error.localizedDescription == "pane closed")
    }
}
