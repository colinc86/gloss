import SwiftUI

/// Follow mode, beside the address field: a plain toolbar button while off; while following, a white crosshair on
/// an accent disc of its own, so it reads as lit at a glance (a toolbar toggle's solid "on" disc hides the
/// symbol). The sidebar's card carries the live state.
struct FollowToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(isOn ? "Following Herdr" : "Follow Herdr", systemImage: "scope")
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.hierarchical)
                .fontWeight(isOn ? .semibold : nil)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .symbolEffect(.bounce, value: isOn)
                // One size on and off, so the address field beside it doesn't shift.
                .frame(width: 28, height: 28)
                .background {
                    if isOn { Circle().fill(Color.accentColor) }
                }
                .contentShape(Circle())
        }
        .help(isOn ? "Following the focused Herdr pane: the explorer and the send target follow it. Click to stop."
                   : "Follow Herdr: the explorer and the send target follow whichever agent pane you focus in Herdr.")
        .accessibilityLabel("Follow Herdr")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
