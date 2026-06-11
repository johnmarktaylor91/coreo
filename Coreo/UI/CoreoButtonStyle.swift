// CoreoButtonStyle.swift
// Coreo
//
// Custom button styles with tactile press feedback. Every tappable
// element in the app should use one of these so the user never
// taps "dead glass."

import SwiftUI

/// Primary style: scale-down + dim on press, spring back on release.
/// Use on all standard icon and text buttons.
struct CoreoButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Prominent style for large CTA buttons (Sync & Go, Export).
/// Deeper press with a subtle brightness shift.
struct CoreoProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// Toolbar icon style: lighter feedback for small icon buttons.
struct CoreoToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Convenience extensions

extension ButtonStyle where Self == CoreoButtonStyle {
    static var coreo: CoreoButtonStyle { CoreoButtonStyle() }
}

extension ButtonStyle where Self == CoreoProminentButtonStyle {
    static var coreoProminent: CoreoProminentButtonStyle { CoreoProminentButtonStyle() }
}

extension ButtonStyle where Self == CoreoToolbarButtonStyle {
    static var coreoToolbar: CoreoToolbarButtonStyle { CoreoToolbarButtonStyle() }
}
