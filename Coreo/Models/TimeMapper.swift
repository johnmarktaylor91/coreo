// TimeMapper.swift
// Coreo
//
// Pure timeline mapping between unified time, clip-local time, and export time.

import Foundation

/// Maps Coreo's unified timeline to clip-local and export-output time.
struct TimeMapper {
    /// Per-clip timing metadata.
    struct Clip: Equatable {
        /// Stable video identity.
        let id: UUID

        /// Timeline offset in seconds.
        let syncOffsetSeconds: Double

        /// Clip duration in seconds.
        let durationSeconds: Double

        /// Optional clip-local trim start.
        let trimStartSeconds: Double?

        /// Optional clip-local trim duration.
        let trimDurationSeconds: Double?

        /// Creates a clip timing descriptor.
        ///
        /// - Parameter video: Video asset to describe.
        init(video: VideoAsset) {
            id = video.id
            syncOffsetSeconds = video.syncOffsetSeconds
            durationSeconds = video.durationSeconds
            trimStartSeconds = video.trimStartSeconds
            trimDurationSeconds = video.trimDurationSeconds
        }

        /// Creates a clip timing descriptor.
        ///
        /// - Parameters:
        ///   - id: Stable video identity.
        ///   - syncOffsetSeconds: Timeline sync offset.
        ///   - durationSeconds: Clip duration.
        ///   - trimStartSeconds: Optional trim start.
        ///   - trimDurationSeconds: Optional trim duration.
        init(
            id: UUID = UUID(),
            syncOffsetSeconds: Double,
            durationSeconds: Double,
            trimStartSeconds: Double? = nil,
            trimDurationSeconds: Double? = nil
        ) {
            self.id = id
            self.syncOffsetSeconds = syncOffsetSeconds
            self.durationSeconds = durationSeconds
            self.trimStartSeconds = trimStartSeconds
            self.trimDurationSeconds = trimDurationSeconds
        }

        /// Timeline start for this clip after trim.
        var timelineStartSeconds: Double {
            syncOffsetSeconds + (trimStartSeconds ?? 0)
        }

        /// Clip-local start after trim.
        var clipStartSeconds: Double {
            trimStartSeconds ?? 0
        }

        /// Clip-local end after trim.
        var clipEndSeconds: Double {
            if let trimDurationSeconds {
                return min(durationSeconds, clipStartSeconds + max(0, trimDurationSeconds))
            }
            return durationSeconds
        }

        /// Timeline end for this clip after trim.
        var timelineEndSeconds: Double {
            syncOffsetSeconds + clipEndSeconds
        }
    }

    /// Clips in project display order.
    let clips: [Clip]

    /// Project-level speed and hold segments.
    let speedSegments: [SpeedSegment]

    /// Creates a time mapper.
    ///
    /// - Parameters:
    ///   - clips: Clip timing metadata.
    ///   - speedSegments: Project speed segments.
    init(clips: [Clip], speedSegments: [SpeedSegment] = []) {
        self.clips = clips
        self.speedSegments = speedSegments
    }

    /// Creates a time mapper from a project.
    ///
    /// - Parameter project: Project whose timing should be mapped.
    init(project: CoreoProject) {
        clips = project.videos.map(Clip.init(video:))
        speedSegments = project.speedSegments
    }

    /// Earliest active timeline time.
    var timelineStartSeconds: Double {
        clips.map(\.timelineStartSeconds).min() ?? 0
    }

    /// Latest active timeline time.
    var timelineEndSeconds: Double {
        clips.map(\.timelineEndSeconds).max() ?? 0
    }

    /// Maps unified timeline time to clip-local time.
    ///
    /// - Parameters:
    ///   - timelineSeconds: Unified timeline time.
    ///   - clipID: Clip identity.
    /// - Returns: Clip-local seconds clamped to the clip's active trim range.
    func clipTime(forTimeline timelineSeconds: Double, clipID: UUID) -> Double? {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return nil }
        let local = timelineSeconds - clip.syncOffsetSeconds
        return min(max(local, clip.clipStartSeconds), clip.clipEndSeconds)
    }

    /// Maps clip-local time to unified timeline time.
    ///
    /// - Parameters:
    ///   - clipSeconds: Clip-local seconds.
    ///   - clipID: Clip identity.
    /// - Returns: Unified timeline seconds clamped to the clip's active trim range.
    func timelineTime(forClip clipSeconds: Double, clipID: UUID) -> Double? {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return nil }
        let local = min(max(clipSeconds, clip.clipStartSeconds), clip.clipEndSeconds)
        return local + clip.syncOffsetSeconds
    }

    /// Returns whether a clip has media at the supplied unified timeline time.
    ///
    /// - Parameters:
    ///   - timelineSeconds: Unified timeline time.
    ///   - clipID: Clip identity.
    /// - Returns: True if the clip is active.
    func isClipActive(atTimeline timelineSeconds: Double, clipID: UUID) -> Bool {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return false }
        let local = timelineSeconds - clip.syncOffsetSeconds
        return local >= clip.clipStartSeconds && local <= clip.clipEndSeconds
    }

    /// Maps unified timeline time to export output time.
    ///
    /// - Parameters:
    ///   - timelineSeconds: Unified timeline time before speed edits.
    ///   - timelineStart: Optional explicit timeline start. Defaults to mapper timeline start.
    /// - Returns: Export/output seconds after speed and hold warping.
    func exportTime(forTimeline timelineSeconds: Double, timelineStart: Double? = nil) -> Double {
        let start = timelineStart ?? timelineStartSeconds
        var mapped = timelineSeconds - start
        for segment in sortedSegments {
            guard timelineSeconds > segment.startTimeSeconds else { continue }
            if segment.isHold {
                mapped += segment.holdDurationSeconds ?? 1
                continue
            }

            guard segment.rate > 0 else { continue }
            let affected = min(timelineSeconds, segment.endTimeSeconds) - segment.startTimeSeconds
            guard affected > 0 else { continue }
            mapped += affected / Double(segment.rate) - affected
        }
        return mapped
    }

    /// Maps export output time back to unified timeline time.
    ///
    /// - Parameters:
    ///   - exportSeconds: Export/output seconds.
    ///   - timelineStart: Optional explicit timeline start. Defaults to mapper timeline start.
    /// - Returns: Unified timeline seconds. Times inside a hold map to that hold's timeline start.
    func timelineTime(forExport exportSeconds: Double, timelineStart: Double? = nil) -> Double {
        let start = timelineStart ?? timelineStartSeconds
        var cursorTimeline = start
        var cursorExport: Double = 0

        for segment in sortedSegments {
            guard segment.startTimeSeconds >= cursorTimeline else { continue }
            let normalDuration = segment.startTimeSeconds - cursorTimeline
            if exportSeconds <= cursorExport + normalDuration {
                return cursorTimeline + (exportSeconds - cursorExport)
            }
            cursorTimeline = segment.startTimeSeconds
            cursorExport += normalDuration

            if segment.isHold {
                let holdDuration = segment.holdDurationSeconds ?? 1
                if exportSeconds <= cursorExport + holdDuration {
                    return segment.startTimeSeconds
                }
                cursorExport += holdDuration
                cursorTimeline = segment.startTimeSeconds
            } else if segment.rate > 0 {
                let mappedDuration = segment.durationSeconds / Double(segment.rate)
                if exportSeconds <= cursorExport + mappedDuration {
                    return segment.startTimeSeconds + (exportSeconds - cursorExport) * Double(segment.rate)
                }
                cursorExport += mappedDuration
                cursorTimeline = segment.endTimeSeconds
            }
        }

        return cursorTimeline + (exportSeconds - cursorExport)
    }

    /// Total export duration for the mapper's timeline range.
    ///
    /// - Returns: Export/output seconds for the mapper timeline end.
    func mappedDurationSeconds() -> Double {
        exportTime(forTimeline: timelineEndSeconds)
    }

    /// Speed segments sorted by start time.
    private var sortedSegments: [SpeedSegment] {
        speedSegments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
    }
}
