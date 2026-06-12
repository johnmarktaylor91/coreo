// CoreoProject.swift
// Coreo
//
// The top-level project model. Contains all state for one multi-angle
// video session: videos, layout, speed, annotations, and trim.

import Foundation

/// The main project data model for a Coreo multi-angle video session.
struct CoreoProject: Codable, Identifiable {
    /// Current project document schema.
    static let currentSchemaVersion: Int = 1

    /// Persisted schema version.
    let schemaVersion: Int

    /// Unique identifier for this project.
    let id: UUID

    /// User-facing project name.
    var name: String

    /// Timestamp when the project was first created.
    var createdAt: Date

    /// Imported video assets in display order.
    var videos: [VideoAsset]

    /// Video ID indicating the sync reference.
    var referenceVideoID: UUID?

    /// Speed and hold modifications applied to the timeline.
    var speedSegments: [SpeedSegment]

    /// Time-stamped annotations (drawings, text, arrows).
    var annotations: [TimedAnnotation]

    /// Start of the user's unified trim range in seconds, or nil if no trim is applied.
    var timelineTrimStartSeconds: Double?

    /// Duration of the user's unified trim range in seconds, or nil if no trim is applied.
    var timelineTrimDurationSeconds: Double?

    /// Video ID indicating which video's audio track to use for export.
    var audioSourceVideoID: UUID?

    // MARK: - Initializer

    /// Creates a new project with sensible defaults.
    ///
    /// - Parameters:
    ///   - id: Stable project identity.
    ///   - name: Project name. Defaults to "Untitled Project".
    ///   - videos: Initial video assets. Defaults to empty.
    ///   - referenceVideoID: Sync reference video ID.
    ///   - audioSourceVideoID: Export/playback audio source ID.
    ///   - createdAt: Creation date.
    init(
        id: UUID = UUID(),
        name: String = "Untitled Project",
        videos: [VideoAsset] = [],
        referenceVideoID: UUID? = nil,
        audioSourceVideoID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.videos = videos
        self.referenceVideoID = referenceVideoID ?? videos.first?.id
        speedSegments = []
        annotations = []
        timelineTrimStartSeconds = nil
        timelineTrimDurationSeconds = nil
        self.audioSourceVideoID = audioSourceVideoID ?? videos.first?.id
    }

    // MARK: - Validation

    /// Clamps stale IDs to valid video identities.
    mutating func sanitizeReferences() {
        guard !videos.isEmpty else {
            referenceVideoID = nil
            audioSourceVideoID = nil
            return
        }
        let ids = Set(videos.map(\.id))
        if referenceVideoID.map({ ids.contains($0) }) != true {
            referenceVideoID = videos.first?.id
        }
        if audioSourceVideoID.map({ ids.contains($0) }) != true {
            audioSourceVideoID = videos.first(where: { $0.audioBitrate > 0 })?.id ?? videos.first?.id
        }
    }

    /// Removes the video with the supplied ID and updates stale references.
    ///
    /// - Parameter id: Video identity to remove.
    mutating func removeVideo(id: UUID) {
        videos.removeAll { $0.id == id }
        sanitizeReferences()
    }

    // MARK: - Lookup Helpers

    /// Returns the display index for a video ID.
    ///
    /// - Parameter id: Video identity.
    /// - Returns: Index in `videos`, or nil if absent.
    func index(forVideoID id: UUID?) -> Int? {
        guard let id else { return nil }
        return videos.firstIndex { $0.id == id }
    }

    /// Returns the video for a stable ID.
    ///
    /// - Parameter id: Video identity.
    /// - Returns: Matching video, or nil.
    func video(id: UUID?) -> VideoAsset? {
        guard let id else { return nil }
        return videos.first { $0.id == id }
    }

    /// Sync offset for the video at the supplied display index.
    ///
    /// - Parameter index: Index in `videos`.
    /// - Returns: Per-clip sync offset, or zero if the index is invalid.
    func syncOffset(at index: Int) -> TimeInterval {
        guard videos.indices.contains(index) else { return 0 }
        return videos[index].syncOffsetSeconds
    }

    /// Project root for this project under the supplied store root.
    ///
    /// - Parameter storeRoot: Root Projects directory.
    /// - Returns: Project directory URL.
    func projectDirectory(in storeRoot: URL) -> URL {
        storeRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - Compatibility Indices

    /// Reference video display index for index-based UI and AVPlayer arrays.
    var referenceVideoIndex: Int {
        get { index(forVideoID: referenceVideoID) ?? 0 }
        set {
            guard videos.indices.contains(newValue) else { return }
            referenceVideoID = videos[newValue].id
        }
    }

    /// Audio source display index for index-based UI and AVPlayer arrays.
    var audioSourceIndex: Int {
        get { index(forVideoID: audioSourceVideoID) ?? 0 }
        set {
            guard videos.indices.contains(newValue) else { return }
            audioSourceVideoID = videos[newValue].id
        }
    }

    // MARK: - Timeline Computed Properties

    /// The earliest point on the timeline (minimum sync offset, often 0 or negative).
    var timelineStartSeconds: Double {
        guard !videos.isEmpty else { return 0 }
        return videos.map(\.syncOffsetSeconds).min() ?? 0
    }

    /// The latest point on the timeline (maximum of each video's offset + duration).
    var timelineEndSeconds: Double {
        guard !videos.isEmpty else { return 0 }
        return videos
            .map { $0.syncOffsetSeconds + $0.durationSeconds }
            .max() ?? 0
    }

    /// Total span of the timeline from earliest start to latest end.
    var timelineDurationSeconds: Double {
        timelineEndSeconds - timelineStartSeconds
    }

    /// The time where ALL videos overlap begins (max of all start offsets).
    var overlapStartSeconds: Double {
        guard !videos.isEmpty else { return 0 }
        return videos.map(\.syncOffsetSeconds).max() ?? 0
    }

    /// The time where ALL videos overlap ends (min of all video end times).
    var overlapEndSeconds: Double {
        guard !videos.isEmpty else { return 0 }
        return videos
            .map { $0.syncOffsetSeconds + $0.durationSeconds }
            .min() ?? 0
    }
}
