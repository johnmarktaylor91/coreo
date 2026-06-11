// HoldMarkerView.swift
// Coreo
//
// Visual markers placed on the timeline at each hold/freeze point.
// Each hold is indicated by a small red pause icon at its timeline position.

import SwiftUI

/// Renders small pause-icon markers on the timeline for hold/freeze segments.
///
/// Placed as an overlay within any timeline strip. Each hold segment gets
/// a red "pause.fill" SF Symbol at 8pt, positioned proportionally along
/// the timeline's width.
struct HoldMarkerView: View {
    /// Hold segments to display (pre-filtered to only holds).
    let holdSegments: [SpeedSegment]

    /// The earliest point on the timeline in seconds.
    let timelineStart: Double

    /// Total span of the timeline in seconds.
    let timelineDuration: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ForEach(holdSegments) { segment in
                let x = xPosition(for: segment.startTimeSeconds, in: width)

                Image(systemName: "pause.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.red)
                    .position(x: x, y: height / 2)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Private

    /// Converts a timeline position to an x-coordinate.
    ///
    /// - Parameters:
    ///   - seconds: Timeline position in seconds.
    ///   - width: Available drawing width.
    /// - Returns: The x-coordinate.
    private func xPosition(for seconds: Double, in width: CGFloat) -> CGFloat {
        guard timelineDuration > 0 else { return 0 }
        let fraction = (seconds - timelineStart) / timelineDuration
        return CGFloat(fraction) * width
    }
}
