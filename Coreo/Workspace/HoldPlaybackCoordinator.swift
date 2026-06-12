// HoldPlaybackCoordinator.swift
// Coreo
//
// Pure hold boundary detection for live playback.

import Foundation

/// Detects hold crossings and returns resume scheduling information.
struct HoldPlaybackCoordinator {
    /// Result of a detected hold crossing.
    struct HoldEvent: Equatable {
        /// Hold segment that was crossed.
        let segment: SpeedSegment

        /// Timeline point to display while held.
        let holdTimelineSeconds: Double

        /// Timeline point to resume from after the hold completes.
        let resumeTimelineSeconds: Double

        /// Wall-clock hold duration after applying playback rate.
        let wallDurationSeconds: Double
    }

    /// Detects the first hold boundary crossed by a tick.
    ///
    /// - Parameters:
    ///   - previousSeconds: Previous timeline time.
    ///   - currentSeconds: Current timeline time.
    ///   - speedMap: Cached speed map to inspect.
    ///   - playbackRate: Current user playback rate.
    /// - Returns: Hold event if a boundary was crossed.
    func crossedHold(
        previousSeconds: Double,
        currentSeconds: Double,
        speedMap: SpeedMap,
        playbackRate: Float
    ) -> HoldEvent? {
        guard currentSeconds >= previousSeconds else { return nil }
        let hold = speedMap.sortedSegments.first { segment in
            segment.isHold
                && previousSeconds < segment.startTimeSeconds
                && currentSeconds >= segment.startTimeSeconds
        }
        guard let hold else { return nil }
        let requestedDuration = max(hold.holdDurationSeconds ?? 1, 0)
        let wallRate = max(Double(playbackRate), 0.01)
        return HoldEvent(
            segment: hold,
            holdTimelineSeconds: hold.startTimeSeconds,
            resumeTimelineSeconds: hold.endTimeSeconds,
            wallDurationSeconds: requestedDuration / wallRate
        )
    }
}
