import Core
import Testing
@testable import Gloss

/// Issue #3: Back and Forward through documents, across folders and hosts.
struct DocumentHistoryTests {
    let a = DocumentHistory.Entry(hostID: .local, path: "/proj-a/README.md")
    let b = DocumentHistory.Entry(hostID: .local, path: "/proj-b/PLAN.md")
    let c = DocumentHistory.Entry(hostID: HostID(rawValue: "h_box"), path: "/home/me/notes.txt")

    @Test func backAndForwardRetraceVisits() {
        var history = DocumentHistory()
        history.visit(a)
        history.visit(b)
        history.visit(c)
        #expect(history.canGoBack && !history.canGoForward)
        #expect(history.goBack() == b)
        #expect(history.goBack() == a)
        #expect(history.goBack() == nil, "nothing before the first")
        #expect(history.current == a)
        #expect(history.goForward() == b)
        #expect(history.goForward() == c)
        #expect(history.goForward() == nil)
    }

    @Test func aNewVisitDropsTheWayForward() {
        var history = DocumentHistory()
        history.visit(a)
        history.visit(b)
        _ = history.goBack()
        history.visit(c)
        #expect(!history.canGoForward)
        #expect(history.recentBack() == [a])
    }

    @Test func revisitsDoNotPileUp() {
        var history = DocumentHistory()
        history.visit(a)
        history.visit(a)
        #expect(!history.canGoBack, "the same document twice is one visit")
        history.visit(b)
        history.visit(a)
        history.visit(b)
        #expect(history.recentBack() == [a], "each place is listed once, at its latest visit")
    }

    @Test func historyIsBoundedAndForgetsMissingPlaces() {
        var history = DocumentHistory()
        for n in 0..<80 { history.visit(.init(hostID: .local, path: "/f\(n)")) }
        #expect(history.back.count == DocumentHistory.limit)
        history.forget(.init(hostID: .local, path: "/f78"))
        #expect(history.goBack() == .init(hostID: .local, path: "/f77"))
    }

    @Test func goingBackPassesOverPlacesThatAreGone() {
        var history = DocumentHistory()
        history.visit(a)
        history.visit(b)
        history.visit(c)
        #expect(history.goBack(skipping: { $0 == b }) == a, "b was deleted")
        #expect(history.current == a && history.goForward() == c, "and is gone from the way forward too")
        #expect(history.goBack(skipping: { _ in true }) == nil)
        #expect(history.current == c, "nothing left to show: stays where it is")
    }
}
