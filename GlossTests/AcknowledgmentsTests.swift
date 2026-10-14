import Foundation
import Testing
@testable import Gloss

/// Help › Acknowledgments carries the license of every package the app resolves, at its resolved version: a package
/// added, updated or removed without running `scripts/acknowledgments.py` fails here instead of shipping without its notice.
@MainActor
struct AcknowledgmentsTests {
    @Test func everyResolvedPackageIsAcknowledged() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resolved = root.appending(path: "Gloss.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        struct Resolved: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { let version: String?; let revision: String? }
                let identity: String
                let state: State
                /// The heading `scripts/acknowledgments.py` writes: the version, or a revision's first 12 characters.
                var heading: String { "== \(identity) \(state.version ?? String((state.revision ?? "").prefix(12))) ==" }
            }
            let pins: [Pin]
        }
        let pins = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: resolved)).pins
        #expect(!pins.isEmpty)
        let text = AcknowledgmentsWindow.text
        for pin in pins {
            #expect(text.contains(pin.heading), "\(pin.heading) is missing: run scripts/acknowledgments.py")
        }
        let headings = text.split(separator: "\n").filter { $0.hasPrefix("== ") && $0 != "== Theme palettes ==" }
        #expect(headings.count == pins.count, "a package that is no longer resolved is still listed: run scripts/acknowledgments.py")
        #expect(text.contains("== Theme palettes =="))
        #expect(text.contains("MIT License"))
    }
}
