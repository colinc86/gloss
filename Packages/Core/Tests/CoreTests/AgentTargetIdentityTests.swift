import Foundation
import Testing
@testable import Core

/// Issue #21: a running agent showed as unavailable because targets were matched by their identity's text.
struct AgentTargetIdentityTests {
    private func herdr(_ json: String, host: HostID = .local) -> AgentTarget {
        AgentTarget(transport: .herdr, hostID: host, label: "claude", identityJSON: json)
    }

    @Test func keyOrderDoesNotMatter() {
        // What one launch wrote and the next one listed for the same pane.
        #expect(herdr(#"{"pane_id":"w6:p1","agent":"claude"}"#).id == herdr(#"{"agent":"claude","pane_id":"w6:p1"}"#).id)
    }

    @Test func fieldsThatChangeWhileAnAgentRunsDoNotMatter() {
        #expect(herdr(#"{"pane_id":"w1:p1","agent":"claude"}"#).id == herdr(#"{"pane_id":"w1:p1","agent":"claude","name":"reviewer"}"#).id,
                "a Herdr agent given a name later, or followed from pane details that carry none")
        let before = AgentTarget(transport: .tmux, hostID: .local, label: "a", identityJSON: #"{"target":"main:0.1","command":"claude","path":"/p"}"#)
        let after = AgentTarget(transport: .tmux, hostID: .local, label: "b", identityJSON: #"{"command":"node","path":"/p/app","target":"main:0.1"}"#)
        #expect(before.id == after.id, "a tmux pane whose command or folder changed")
        let session = AgentTarget(transport: .opencode, hostID: .local, label: "s", identityJSON: #"{"base_url":"http:\/\/127.0.0.1:4096","session_id":"ses_1"}"#)
        let same = AgentTarget(transport: .opencode, hostID: .local, label: "s", identityJSON: #"{"session_id":"ses_1","base_url":"http://127.0.0.1:4096"}"#)
        #expect(session.id == same.id, "escaped or not")
    }

    @Test func differentAgentsStayDifferent() {
        #expect(herdr(#"{"pane_id":"w1:p1","agent":"claude"}"#).id != herdr(#"{"pane_id":"w1:p2","agent":"claude"}"#).id)
        #expect(herdr(#"{"pane_id":"w1:p1","agent":"claude"}"#).id != herdr(#"{"pane_id":"w1:p1","agent":"codex"}"#).id, "another agent in the pane")
        #expect(herdr(#"{"pane_id":"w1:p1","agent":"claude"}"#).id != herdr(#"{"pane_id":"w1:p1","agent":"claude"}"#, host: HostID(rawValue: "h_box")).id)
        let one = AgentTarget(transport: .tmux, hostID: .local, label: "x", identityJSON: #"{"pane":"0"}"#)
        let two = AgentTarget(transport: .tmux, hostID: .local, label: "x", identityJSON: #"{"pane":"9"}"#)
        #expect(one.id != two.id, "an identity without the usual fields is compared whole")
    }
}

struct DeadlineTests {
    @Test func returnsAtTheDeadlineEvenWhenTheWorkIgnoresCancellation() async {
        let start = ContinuousClock.now
        let value: Int? = await withDeadline(.milliseconds(100)) {
            // An ssh exec with its own longer timeout: it doesn't stop when cancelled.
            let until = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(10)) }
            return 1
        }
        #expect(value == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await withDeadline(.seconds(1)) { 7 } == 7)
    }
}
