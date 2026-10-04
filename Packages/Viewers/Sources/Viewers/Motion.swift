import AppKit
import SwiftUI

/// The app's motion, shared by every target: quick and physical by default, and calm when the person has asked
/// macOS to reduce motion (System Settings > Accessibility > Display): no springs, no overshoot, no looping, just
/// a brief ease so changes are still noticed.
public enum Motion {
    /// Tests set this; otherwise the system setting decides.
    nonisolated(unsafe) public static var reducedOverride: Bool?

    public static var isReduced: Bool {
        reducedOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static let calm = Animation.easeInOut(duration: 0.12)

    /// Direct feedback: hover, press, toggles.
    public static var snappy: Animation { isReduced ? calm : .snappy(duration: 0.18) }
    /// Content that moves or changes state.
    public static var smooth: Animation { isReduced ? calm : .smooth(duration: 0.28) }
    /// Rare arrivals that deserve attention.
    public static var bouncy: Animation { isReduced ? calm : .bouncy(duration: 0.35, extraBounce: 0.05) }
    /// Whether anything may loop forever (a live pulse); never when motion is reduced.
    public static var allowsLooping: Bool { !isReduced }
}

extension AnyTransition {
    /// This transition, or a plain fade when the person has asked macOS to reduce motion: things that slide or grow
    /// arrive in place instead. Every transition that moves or scales a view goes through it.
    public var calmed: AnyTransition { Motion.isReduced ? .opacity : self }
}
