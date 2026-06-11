// DesignSystem.swift
// Coreo
//
// Single source of truth for colors, spacing, typography, and animation
// curves. Every UI file should reference these constants instead of
// hardcoding values. Keeps the app visually consistent and makes
// sweeping changes trivial.

import SwiftUI

// MARK: - Colors

enum CoreoColor {
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.21)
    static let accentGradientEnd = Color(red: 0.91, green: 0.24, blue: 0.24)

    static let backgroundDeep = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let backgroundMedium = Color(red: 0.1, green: 0.1, blue: 0.1)
    static let backgroundPanel = Color(red: 0.06, green: 0.06, blue: 0.06)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.7)
    static let textTertiary = Color.white.opacity(0.5)
    static let textDisabled = Color.white.opacity(0.35)

    static let error = Color(red: 1.0, green: 0.3, blue: 0.3)
}

// MARK: - Spacing Scale (4pt base)

enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Animation Curves

enum CoreoAnimation {
    /// Snappy interactive feedback (button presses, toggles).
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)

    /// Standard state transitions (panels, toolbars).
    static let standard = Animation.easeInOut(duration: 0.25)

    /// Slow, deliberate transitions (screen changes, overlays).
    static let slow = Animation.easeInOut(duration: 0.35)
}

// MARK: - Corner Radii

enum CornerRadius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 8
    static let large: CGFloat = 14
    static let xl: CGFloat = 16
    static let card: CGFloat = 20
}
