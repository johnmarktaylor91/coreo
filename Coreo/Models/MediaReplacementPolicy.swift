// MediaReplacementPolicy.swift
// Coreo
//
// Pure decisions for missing-media replacement.

import Foundation

/// Decision helper for validating replacement media.
enum MediaReplacementPolicy {
    /// Maximum silent duration drift in seconds.
    static let durationToleranceSeconds: Double = 0.25

    /// Whether a replacement duration should warn before use.
    ///
    /// - Parameters:
    ///   - originalDuration: Duration recorded in the project.
    ///   - replacementDuration: Duration of the newly picked clip.
    ///   - tolerance: Maximum silent difference.
    /// - Returns: True when the user should be warned.
    static func requiresDurationWarning(
        originalDuration: Double,
        replacementDuration: Double,
        tolerance: Double = durationToleranceSeconds
    ) -> Bool {
        abs(originalDuration - replacementDuration) > tolerance
    }
}
