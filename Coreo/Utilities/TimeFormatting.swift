// TimeFormatting.swift
// Coreo
//
// Utilities for formatting time durations into human-readable strings
// used throughout the timeline, annotations, and export UI.

import Foundation

/// Time formatting utilities for displaying durations in various formats.
enum TimeFormatting {
    /// Formats seconds as "M:SS.ff" (e.g., "1:23.45").
    ///
    /// - Parameter seconds: Duration in seconds. Negative, NaN, and infinite values are handled.
    /// - Returns: A formatted string.
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--.--" }
        let clamped = max(0, seconds)

        let totalSeconds = Int(clamped)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        let fraction = clamped - Double(totalSeconds)
        let centiseconds = Int(round(fraction * 100))

        // Handle rounding: 99.999... -> next second
        if centiseconds >= 100 {
            return format(Double(totalSeconds + 1))
        }

        return String(format: "%d:%02d.%02d", minutes, secs, centiseconds)
    }

    /// Formats seconds as "M:SS" (e.g., "1:23").
    ///
    /// - Parameter seconds: Duration in seconds. Negative, NaN, and infinite values are handled.
    /// - Returns: A formatted string.
    static func formatShort(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let clamped = max(0, seconds)

        let totalSeconds = Int(clamped)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60

        return String(format: "%d:%02d", minutes, secs)
    }

    /// Formats seconds as "H:MM:SS" for long durations (over 1 hour).
    ///
    /// For durations under 1 hour, still uses "H:MM:SS" with 0 hours.
    ///
    /// - Parameter seconds: Duration in seconds. Negative, NaN, and infinite values are handled.
    /// - Returns: A formatted string.
    static func formatLong(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--:--" }
        let clamped = max(0, seconds)

        let totalSeconds = Int(clamped)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
}
