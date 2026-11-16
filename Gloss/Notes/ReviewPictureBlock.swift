import Core
import SwiftUI
import Viewers

/// A titled block of the review card holding a window onto the document as rendered around the note
/// (`ExcerptRenderer`): the one kept at the send, or one drawn now. Loads when it appears and again when `key`
/// changes; says so when there is nothing to show.
struct ReviewPictureBlock<Key: Hashable>: View {
    let title: String
    let key: Key
    let load: @MainActor () async -> CGImage?
    @State private var image: CGImage?
    @State private var loaded = false

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Group {
                if let image {
                    // A window is drawn with the anchor in its middle. Short of room it is cut evenly from both
                    // ends, so the anchor stays in the middle at a readable size; a web page's capture has its own
                    // shape and is shown whole.
                    let window = ExcerptProducer.window
                    if abs(CGFloat(image.width) / CGFloat(image.height) - window.width / window.height) < 0.01 {
                        Color.clear
                            .aspectRatio(window.width / window.height, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: window.height)
                            .overlay {
                                Image(decorative: image, scale: window.scale)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                            .clipped()
                    } else {
                        Image(decorative: image, scale: window.scale)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: window.height)
                    }
                } else if loaded {
                    Text("Nothing to show")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                }
            }
            .clipShape(Self.shape)
            .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.1)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) {
            loaded = false
            image = nil
            let result = await load()
            // An edit under the card starts a new load; one from before must not land after it.
            guard !Task.isCancelled else { return }
            image = result
            loaded = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
