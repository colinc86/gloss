import SwiftUI

/// Follow mode, at the left of the folder dropdown and as tall as it: quiet like the dropdown while off; while
/// following, a white crosshair on an accent fill in the dropdown's shape, so it reads as lit at a glance. The
/// card under it carries the live state.
struct FollowToggle: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: "scope")
                .symbolRenderingMode(.hierarchical)
                .fontWeight(isOn ? .semibold : .regular)
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .symbolEffect(.bounce, value: isOn)
                .frame(minWidth: 34, maxHeight: .infinity)
                .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.07 : 0.035)), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .animation(DS.Motion.snappy, value: isOn)
        .help(isOn ? "Following the focused Herdr pane: the explorer and the send target follow it. Click to stop."
                   : "Follow Herdr: the explorer and the send target follow whichever agent pane you focus in Herdr.")
        .accessibilityLabel("Follow Herdr")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
