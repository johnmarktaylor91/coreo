// SpeedSegmentModel.swift
// Coreo
//
// Models for playback speed and hold/freeze modifications on the timeline.
// SpeedSegment defines a time range with a playback rate; SpeedMap manages
// the collection and handles overlap resolution.

import Foundation

/// A time range on the timeline with a modified playback rate.
struct SpeedSegment: Codable, Identifiable {
    /// Unique identifier for this segment.
    let id: UUID

    /// Timeline time (seconds) where this speed modification begins.
    var startTimeSeconds: Double

    /// Duration (seconds) of the modified range.
    var durationSeconds: Double

    /// Playback rate multiplier. 0.0 = freeze/hold, 0.25-2.0 = speed.
    var rate: Float

    /// Duration of the freeze frame when `rate` is 0. Only meaningful for hold segments.
    var holdDurationSeconds: Double?

    /// Timeline time (seconds) where this speed modification ends.
    var endTimeSeconds: Double {
        startTimeSeconds + durationSeconds
    }

    /// Whether this segment represents a freeze/hold frame.
    var isHold: Bool {
        rate == 0.0
    }
}

/// Manages a collection of speed segments and provides lookup/mutation operations.
struct SpeedMap {
    /// The underlying speed segments.
    var segments: [SpeedSegment]

    /// Creates a speed map from the given segments.
    ///
    /// - Parameter segments: Initial segments. Defaults to empty.
    init(segments: [SpeedSegment] = []) {
        self.segments = segments
    }

    /// Returns the playback rate at a given timeline time.
    ///
    /// If multiple segments overlap at the given time, the one with the latest
    /// start time takes precedence. Returns 1.0 (normal speed) if no segment
    /// covers the time.
    ///
    /// - Parameter timeSeconds: The timeline position to query.
    /// - Returns: The playback rate at that time.
    func rate(at timeSeconds: Double) -> Float {
        // Find all segments covering this time, prefer the latest-starting one
        let covering = segments
            .filter { timeSeconds >= $0.startTimeSeconds && timeSeconds < $0.endTimeSeconds }
            .sorted { $0.startTimeSeconds > $1.startTimeSeconds }

        return covering.first?.rate ?? 1.0
    }

    /// All segments sorted by start time.
    var sortedSegments: [SpeedSegment] {
        segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
    }

    /// Adds a new speed segment, splitting or removing any overlapping existing segments.
    ///
    /// Existing segments that partially overlap the new segment are trimmed.
    /// Existing segments that are fully contained within the new segment are removed.
    ///
    /// - Parameter segment: The segment to add.
    mutating func addSegment(_ segment: SpeedSegment) {
        var updated: [SpeedSegment] = []

        for existing in segments {
            // No overlap — keep existing unchanged
            if existing.endTimeSeconds <= segment.startTimeSeconds
                || existing.startTimeSeconds >= segment.endTimeSeconds
            {
                updated.append(existing)
                continue
            }

            // Existing is fully contained by new segment — remove it
            if existing.startTimeSeconds >= segment.startTimeSeconds
                && existing.endTimeSeconds <= segment.endTimeSeconds
            {
                continue
            }

            // Existing starts before new segment — keep the left portion
            if existing.startTimeSeconds < segment.startTimeSeconds {
                var leftPart = existing
                leftPart.durationSeconds = segment.startTimeSeconds - existing.startTimeSeconds
                updated.append(leftPart)
            }

            // Existing ends after new segment — keep the right portion
            if existing.endTimeSeconds > segment.endTimeSeconds {
                var rightPart = existing
                rightPart.startTimeSeconds = segment.endTimeSeconds
                rightPart.durationSeconds = existing.endTimeSeconds - segment.endTimeSeconds
                updated.append(rightPart)
            }
        }

        updated.append(segment)
        segments = updated
    }

    /// Removes the segment with the given ID.
    ///
    /// - Parameter id: The unique identifier of the segment to remove.
    mutating func removeSegment(id: UUID) {
        segments.removeAll { $0.id == id }
    }
}
