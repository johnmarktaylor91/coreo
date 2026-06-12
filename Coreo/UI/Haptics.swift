// Haptics.swift
// Coreo
//
// Centralized haptic feedback. Keeps haptic calls consistent and
// makes it easy to disable them globally if needed.

import UIKit

@MainActor
enum Haptic {
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Light tap — play/pause, tool selection, navigation.
    static func light() {
        lightImpact.impactOccurred()
    }

    /// Medium tap — export start, sync start, significant actions.
    static func medium() {
        mediumImpact.impactOccurred()
    }

    /// Selection tick — speed changes, scrubbing across markers.
    static func tick() {
        selection.selectionChanged()
    }

    /// Success — export complete.
    static func success() {
        notification.notificationOccurred(.success)
    }

    /// Error — sync failure, export failure.
    static func error() {
        notification.notificationOccurred(.error)
    }
}
