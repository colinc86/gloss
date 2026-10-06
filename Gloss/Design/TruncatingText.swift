import SwiftUI

/// Text cut to `lineLimit` lines unless `expanded`, that reports whether the collapsed form cuts anything. The answer
/// comes from two unseen copies, uncut and cut, so it holds steady while the text is open: a "Show more" that
/// measured what's on screen would vanish the moment it was pressed.
struct TruncatingText: View {
    let text: Text
    let lineLimit: Int
    var expanded = false
    @Binding var isCut: Bool
    @State private var fullHeight: CGFloat = 0
    @State private var cutHeight: CGFloat = 0

    var body: some View {
        text
            .lineLimit(expanded ? nil : lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .background(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    text
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
                    text
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { cutHeight = $0 }
                }
                .hidden()
                .accessibilityHidden(true)
            }
            .onChange(of: fullHeight > cutHeight + 1, initial: true) { _, cut in
                if isCut != cut { isCut = cut }
            }
    }
}
