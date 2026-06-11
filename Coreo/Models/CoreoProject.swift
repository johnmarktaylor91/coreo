// CoreoProject.swift
// Coreo
//
// The top-level project model. Contains all state for one multi-angle
// video session: videos, sync offsets, layout, speed, annotations, and trim.

import Foundation

/// User-specified panel positions and sizes for the split-screen layout.
struct LayoutOverrides: Codable {
    /// Normalized (0-1) rectangles for each panel position.
    var panelRects: [CGRect]
}

/// The main project data model for a Coreo multi-angle video session.
struct CoreoProject: Codable, Identifiable {
    /// Unique identifier for this project.
    let id: UUID

    /// User-facing project name.
    var name: String

    /// Timestamp when the project was first created.
    var createdAt: Date

    /// Imported video assets in display order.
    var videos: [VideoAsset]

    /// Index into `videos` indicating which video is the sync reference (offset = 0).
    var referenceVideoIndex: Int

    /// Per-video time offset in seconds relative to the reference video.
    /// `syncOffsets[referenceVideoIndex]` should always be 0.
    var syncOffsets: [TimeInterval]

    /// Optional user-specified panel layout overrides.
    var layoutOverrides: LayoutOverrides?

    /// Optional per-panel crop rectangles in normalized (0-1) coordinates, keyed by video index.
    var cropOverrides: [Int: CGRect]?

    /// Speed and hold modifications applied to the timeline.
    var speedSegments: [SpeedSegment]

    /// Time-stamped annotations (drawings, text, arrows).
    var annotations: [TimedAnnotation]

    /// Start of the user's trim range in seconds, or nil if no trim is applied.
    var timelineTrimStartSeconds: Double?

    /// Duration of the user's trim range in seconds, or nil if no trim is applied.
    var timelineTrimDurationSeconds: Double?

    /// Index into `videos` indicating which video's audio track to use for export.
    var audioSourceIndex: Int

    // MARK: - Initializer

    /// Creates a new project with sensible defaults.
    ///
    /// - Parameters:
    ///   - name: Project name. Defaults to "Untitled Project".
    ///   - videos: Initial video assets. Defaults to empty.
    init(
        id: UUID = UUID(),
        name: String = "Untitled Project",
        videos: [VideoAsset] = [],
        referenceVideoIndex: Int = 0,
        syncOffsets: [TimeInterval]? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.videos = videos
        self.referenceVideoIndex = referenceVideoIndex
        self.syncOffsets = syncOffsets ?? Array(repeating: 0.0, count: videos.count)
        self.layoutOverrides = nil
        self.cropOverrides = nil
        self.speedSegments = []
        self.annotations = []
        self.timelineTrimStartSeconds = nil
        self.timelineTrimDurationSeconds = nil
        self.audioSourceIndex = 0
    }

    // MARK: - Validation

    /// Clamps stale indices to valid ranges. Call after any mutation that
    /// changes the `videos` array (add/remove/reorder).
    mutating func sanitizeIndices() {
        if videos.isEmpty {
            referenceVideoIndex = 0
            audioSourceIndex = 0
            syncOffsets = []
            return
        }
        referenceVideoIndex = min(referenceVideoIndex, videos.count - 1)
        audioSourceIndex = min(audioSourceIndex, videos.count - 1)
        if syncOffsets.count != videos.count {
            syncOffsets = Array(repeating: 0.0, count: videos.count)
        }
    }

    // MARK: - Timeline Computed Properties

    /// The earliest point on the timeline (minimum sync offset, often 0 or negative).
    var timelineStartSeconds: Double {
        guard !syncOffsets.isEmpty else { return 0 }
        return syncOffsets.min() ?? 0
    }

    /// The latest point on the timeline (maximum of each video's offset + duration).
    var timelineEndSeconds: Double {
        guard !videos.isEmpty, videos.count == syncOffsets.count else { return 0 }
        var maxEnd: Double = 0
        for i in videos.indices {
            let videoEnd = syncOffsets[i] + videos[i].durationSeconds
            maxEnd = max(maxEnd, videoEnd)
        }
        return maxEnd
    }

    /// Total span of the timeline from earliest start to latest end.
    var timelineDurationSeconds: Double {
        return timelineEndSeconds - timelineStartSeconds
    }

    /// The time where ALL videos overlap begins (max of all start offsets).
    var overlapStartSeconds: Double {
        guard !syncOffsets.isEmpty else { return 0 }
        return syncOffsets.max() ?? 0
    }

    /// The time where ALL videos overlap ends (min of all video end times).
    var overlapEndSeconds: Double {
        guard !videos.isEmpty, videos.count == syncOffsets.count else { return 0 }
        var minEnd: Double = .greatestFiniteMagnitude
        for i in videos.indices {
            let videoEnd = syncOffsets[i] + videos[i].durationSeconds
            minEnd = min(minEnd, videoEnd)
        }
        return minEnd == .greatestFiniteMagnitude ? 0 : minEnd
    }

    // MARK: - Persistence

    /// The filename used for on-disk storage.
    private static let filename = "coreo_project.json"

    /// Returns the full file URL in the app's Documents directory.
    private static var fileURL: URL {
        let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!  // Documents directory always exists on iOS
        return documentsDirectory.appendingPathComponent(filename)
    }

    /// Persists this project to the app's Documents directory as JSON.
    func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: CoreoProject.fileURL, options: .atomic)
    }

    /// Loads a previously saved project from the Documents directory.
    ///
    /// - Returns: The decoded project, or nil if no saved file exists or decoding fails.
    static func load() -> CoreoProject? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CoreoProject.self, from: data)
        } catch {
            return nil
        }
    }
}
