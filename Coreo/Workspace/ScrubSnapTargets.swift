// ScrubSnapTargets.swift
// Coreo
//
// Pure timeline landmark collection and snapping for interactive scrubs.

import Foundation

/// Sorted timeline landmarks used for interactive scrub snapping.
struct ScrubSnapTargets: Equatable {
    /// Unique sorted target times.
    let times: [Double]

    /// Builds snap targets from timeline landmarks.
    ///
    /// - Parameters:
    ///   - annotations: Annotation ranges whose start times should snap.
    ///   - speedSegments: Speed and hold segments whose boundaries should snap.
    ///   - timelineStart: Timeline start time.
    ///   - timelineEnd: Timeline end time.
    /// - Returns: Sorted unique snap targets.
    static func build(
        annotations: [TimedAnnotation],
        speedSegments: [SpeedSegment],
        timelineStart: Double,
        timelineEnd: Double
    ) -> ScrubSnapTargets {
        var candidates = [timelineStart, timelineEnd]
        candidates.append(contentsOf: annotations.map(\.startTimeSeconds))
        for segment in speedSegments {
            candidates.append(segment.startTimeSeconds)
            candidates.append(segment.endTimeSeconds)
        }
        let unique = candidates
            .filter(\.isFinite)
            .sorted()
            .reduce(into: [Double]()) { result, time in
                guard result.last.map({ abs($0 - time) <= 0.000_001 }) != true else { return }
                result.append(time)
            }
        return ScrubSnapTargets(times: unique)
    }

    /// Snaps a candidate time to the nearest target inside the radius.
    ///
    /// - Parameters:
    ///   - candidateSeconds: Finger-derived timeline time.
    ///   - radiusSeconds: Snap radius in seconds.
    ///   - isEnabled: Whether snapping is active for this seek path.
    /// - Returns: Snapped time or the original candidate.
    func snap(
        candidateSeconds: Double,
        radiusSeconds: Double,
        isEnabled: Bool = true
    ) -> Double {
        snappedTarget(candidateSeconds: candidateSeconds, radiusSeconds: radiusSeconds, isEnabled: isEnabled)
            ?? candidateSeconds
    }

    /// Returns the nearest target inside the radius.
    ///
    /// - Parameters:
    ///   - candidateSeconds: Finger-derived timeline time.
    ///   - radiusSeconds: Snap radius in seconds.
    ///   - isEnabled: Whether snapping is active for this seek path.
    /// - Returns: The target to snap to, or nil.
    func snappedTarget(
        candidateSeconds: Double,
        radiusSeconds: Double,
        isEnabled: Bool = true
    ) -> Double? {
        guard isEnabled, radiusSeconds >= 0, !times.isEmpty else { return nil }
        var bestTime: Double?
        var bestDistance = Double.greatestFiniteMagnitude

        for time in times {
            let distance = abs(time - candidateSeconds)
            guard distance <= radiusSeconds else { continue }
            if distance < bestDistance || (distance == bestDistance && time < (bestTime ?? time)) {
                bestDistance = distance
                bestTime = time
            }
        }

        return bestTime
    }
}
