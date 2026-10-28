import SwiftUI

extension View {
    /// Shows the pointing hand while the pointer is over this, as over a link, so it reads as
    /// something to click.
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        modifier(PointingHand(enabled: enabled))
    }
}

private struct PointingHand: ViewModifier {
    let enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { set($0 && enabled) }
            // A click often takes the view away with the pointer still on it, and then no
            // hover-out ever comes.
            .onDisappear { set(false) }
    }

    private func set(_ on: Bool) {
        guard on != pushed else { return }
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        pushed = on
    }
}
