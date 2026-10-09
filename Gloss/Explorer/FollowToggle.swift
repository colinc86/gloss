import SwiftUI

/// Follow mode, in the bar under the tree beside the hidden-files eye and drawn like it: a secondary crosshair while
/// off, tinted while following, bouncing as it turns on or off. The card at the top of the sidebar carries the
/// live state.
struct FollowToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Image(systemName: "scope")
                .fontWeight(isOn ? .semibold : .regular)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: isOn)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .help(isOn ? "Following the focused Herdr pane: the explorer and the send target follow it. Click to stop."
                   : "Follow Herdr: the explorer and the send target follow whichever agent pane you focus in Herdr.")
        .accessibilityLabel("Follow Herdr")
    }
}
