// VideoAsset.swift
// Coreo
//
// Codable model representing one imported video file with metadata
// extracted from AVFoundation.

import AVFoundation
import CoreMedia
import UIKit

/// Errors that can occur when creating a VideoAsset from a URL.
enum VideoAssetError: Error, LocalizedError {
    case noVideoTrack
    case noAudioTrack
    case invalidDuration
    case thumbnailGenerationFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "The file does not contain a video track."
        case .noAudioTrack:
            "The file does not contain an audio track."
        case .invalidDuration:
            "The video has an invalid or unreadable duration."
        case .thumbnailGenerationFailed:
            "Failed to generate a thumbnail image from the video."
        }
    }
}

/// Recovery state for a video whose copied media file cannot be found.
enum MediaAvailability: Codable, Equatable {
    /// The copied media file exists.
    case available

    /// The copied media file is missing from disk.
    case missing
}

/// Represents a single imported video file with pre-extracted metadata.
struct VideoAsset: Codable, Identifiable {
    /// Unique identifier for this video asset.
    let id: UUID

    /// Project-relative media path, usually `media/<filename>`.
    var relativePath: String

    /// Original imported filename for display.
    var originalFilename: String

    /// Video duration in seconds.
    let durationSeconds: Double

    /// Native video dimensions (width x height) in pixels.
    let dimensions: CGSize

    /// Audio bitrate in bits per second.
    let audioBitrate: Int

    /// Audio sample rate in Hz.
    let audioSampleRate: Int

    /// JPEG thumbnail data for the import screen display.
    var thumbnailData: Data?

    /// Time offset in seconds relative to the sync reference.
    var syncOffsetSeconds: TimeInterval

    /// Sync state reported by the audio sync engine.
    var syncStatus: SyncStatus

    /// Optional normalized auto-crop rectangle.
    var autoCropRect: CGRect?

    /// Optional normalized manual crop rectangle.
    var manualCropRect: CGRect?

    /// Whether preview should horizontally mirror this angle.
    var isMirrored: Bool

    /// Optional normalized manual layout override for this panel.
    var panelRectOverride: CGRect?

    /// Optional per-clip trim start in local clip seconds.
    var trimStartSeconds: Double?

    /// Optional per-clip trim duration in local clip seconds.
    var trimDurationSeconds: Double?

    /// Authoring canvas size used by future annotation rendering.
    var annotationCanvasSize: CGSize?

    /// Whether the copied media file is available on disk.
    var mediaAvailability: MediaAvailability

    // MARK: - Initializer

    /// Creates a video asset.
    init(
        id: UUID = UUID(),
        relativePath: String,
        originalFilename: String? = nil,
        durationSeconds: Double,
        dimensions: CGSize,
        audioBitrate: Int,
        audioSampleRate: Int,
        thumbnailData: Data?,
        syncOffsetSeconds: TimeInterval = 0,
        syncStatus: SyncStatus = .synced,
        autoCropRect: CGRect? = nil,
        manualCropRect: CGRect? = nil,
        isMirrored: Bool = false,
        panelRectOverride: CGRect? = nil,
        trimStartSeconds: Double? = nil,
        trimDurationSeconds: Double? = nil,
        annotationCanvasSize: CGSize? = nil,
        mediaAvailability: MediaAvailability = .available
    ) {
        self.id = id
        self.relativePath = relativePath
        self.originalFilename = originalFilename ?? URL(fileURLWithPath: relativePath).lastPathComponent
        self.durationSeconds = durationSeconds
        self.dimensions = dimensions
        self.audioBitrate = audioBitrate
        self.audioSampleRate = audioSampleRate
        self.thumbnailData = thumbnailData
        self.syncOffsetSeconds = syncOffsetSeconds
        self.syncStatus = syncStatus
        self.autoCropRect = autoCropRect
        self.manualCropRect = manualCropRect
        self.isMirrored = isMirrored
        self.panelRectOverride = panelRectOverride
        self.trimStartSeconds = trimStartSeconds
        self.trimDurationSeconds = trimDurationSeconds
        self.annotationCanvasSize = annotationCanvasSize
        self.mediaAvailability = mediaAvailability
    }

    /// Coding keys with decode defaults for additive model fields.
    private enum CodingKeys: String, CodingKey {
        case id
        case relativePath
        case originalFilename
        case durationSeconds
        case dimensions
        case audioBitrate
        case audioSampleRate
        case thumbnailData
        case syncOffsetSeconds
        case syncStatus
        case autoCropRect
        case manualCropRect
        case isMirrored
        case panelRectOverride
        case trimStartSeconds
        case trimDurationSeconds
        case annotationCanvasSize
        case mediaAvailability
    }

    /// Decodes a video asset, defaulting additive optional state for older project files.
    ///
    /// - Parameter decoder: Decoder containing a persisted video asset.
    /// - Throws: Decoding errors for required media metadata.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        originalFilename = try container.decodeIfPresent(String.self, forKey: .originalFilename)
            ?? URL(fileURLWithPath: relativePath).lastPathComponent
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        dimensions = try container.decode(CGSize.self, forKey: .dimensions)
        audioBitrate = try container.decode(Int.self, forKey: .audioBitrate)
        audioSampleRate = try container.decode(Int.self, forKey: .audioSampleRate)
        thumbnailData = try container.decodeIfPresent(Data.self, forKey: .thumbnailData)
        syncOffsetSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .syncOffsetSeconds) ?? 0
        syncStatus = try container.decodeIfPresent(SyncStatus.self, forKey: .syncStatus) ?? .synced
        autoCropRect = try container.decodeIfPresent(CGRect.self, forKey: .autoCropRect)
        manualCropRect = try container.decodeIfPresent(CGRect.self, forKey: .manualCropRect)
        isMirrored = try container.decodeIfPresent(Bool.self, forKey: .isMirrored) ?? false
        panelRectOverride = try container.decodeIfPresent(CGRect.self, forKey: .panelRectOverride)
        trimStartSeconds = try container.decodeIfPresent(Double.self, forKey: .trimStartSeconds)
        trimDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .trimDurationSeconds)
        annotationCanvasSize = try container.decodeIfPresent(CGSize.self, forKey: .annotationCanvasSize)
        mediaAvailability = try container.decodeIfPresent(MediaAvailability.self, forKey: .mediaAvailability) ?? .available
    }

    // MARK: - Computed Properties

    /// Effective crop rectangle, preferring a manual override.
    var effectiveCropRect: CGRect? {
        manualCropRect ?? autoCropRect
    }

    /// Duration as a CMTime for AVFoundation interop.
    var cmTimeDuration: CMTime {
        CMTime(seconds: durationSeconds, preferredTimescale: 600)
    }

    /// Human-readable formatted duration string (e.g., "1:23").
    var formattedDuration: String {
        TimeFormatting.formatShort(durationSeconds)
    }

    /// Resolves the media file URL inside the supplied project root.
    ///
    /// - Parameter projectRoot: Root directory for this project.
    /// - Returns: Absolute file URL to the copied media file.
    func mediaURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(relativePath)
    }

    // MARK: - Factory

    /// Creates a fully-populated VideoAsset by extracting metadata from the file at the given URL.
    ///
    /// - Parameters:
    ///   - url: A file URL pointing to a video file.
    ///   - relativePath: Project-relative media path to persist.
    /// - Returns: A `VideoAsset` with duration, dimensions, audio info, and thumbnail populated.
    /// - Throws: `VideoAssetError` if required tracks are missing or thumbnail generation fails.
    static func from(url: URL, relativePath: String) async throws -> VideoAsset {
        let asset = AVURLAsset(url: url)

        // Load duration and tracks concurrently
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let videoTrack = videoTracks.first else {
            throw VideoAssetError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        let transformedSize = naturalSize.applying(transform)
        let correctedDimensions = CGSize(
            width: abs(transformedSize.width),
            height: abs(transformedSize.height)
        )

        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0.1 else {
            throw VideoAssetError.invalidDuration
        }

        let safeDimensions = CGSize(
            width: max(correctedDimensions.width, 1),
            height: max(correctedDimensions.height, 1)
        )

        var sampleRate = 0
        var bitrate = 0
        if let audioTrack = audioTracks.first {
            let audioFormatDescriptions = try await audioTrack.load(.formatDescriptions)
            let estimatedDataRate = try await audioTrack.load(.estimatedDataRate)
            if let formatDescription = audioFormatDescriptions.first {
                let absd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
                if let streamSampleRate = absd?.pointee.mSampleRate {
                    sampleRate = Int(streamSampleRate)
                }
            }
            bitrate = max(1, Int(estimatedDataRate))
        }

        let thumbnailTime = CMTime(
            seconds: durationSeconds * 0.25,
            preferredTimescale: 600
        )

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 320, height: 320)

        let thumbnailData: Data?
        do {
            let (cgImage, _) = try await imageGenerator.image(at: thumbnailTime)
            let uiImage = UIImage(cgImage: cgImage)
            thumbnailData = uiImage.jpegData(compressionQuality: 0.7)
        } catch {
            throw VideoAssetError.thumbnailGenerationFailed
        }

        return VideoAsset(
            id: UUID(),
            relativePath: relativePath,
            originalFilename: url.lastPathComponent,
            durationSeconds: durationSeconds,
            dimensions: safeDimensions,
            audioBitrate: bitrate,
            audioSampleRate: sampleRate,
            thumbnailData: thumbnailData
        )
    }
}
