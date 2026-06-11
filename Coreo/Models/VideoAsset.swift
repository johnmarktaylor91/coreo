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
            return "The file does not contain a video track."
        case .noAudioTrack:
            return "The file does not contain an audio track."
        case .invalidDuration:
            return "The video has an invalid or unreadable duration."
        case .thumbnailGenerationFailed:
            return "Failed to generate a thumbnail image from the video."
        }
    }
}

/// Represents a single imported video file with pre-extracted metadata.
struct VideoAsset: Codable, Identifiable {
    /// Unique identifier for this video asset.
    let id: UUID

    /// File URL pointing to the video in the app sandbox or photo library.
    let localURL: URL

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

    // MARK: - Computed Properties

    /// Duration as a CMTime for AVFoundation interop.
    var cmTimeDuration: CMTime {
        CMTime(seconds: durationSeconds, preferredTimescale: 600)
    }

    /// Human-readable formatted duration string (e.g., "1:23").
    var formattedDuration: String {
        TimeFormatting.formatShort(durationSeconds)
    }

    // MARK: - Factory

    /// Creates a fully-populated VideoAsset by extracting metadata from the file at the given URL.
    ///
    /// - Parameter url: A file URL pointing to a video file.
    /// - Returns: A `VideoAsset` with duration, dimensions, audio info, and thumbnail populated.
    /// - Throws: `VideoAssetError` if required tracks are missing or thumbnail generation fails.
    static func from(url: URL) async throws -> VideoAsset {
        let asset = AVURLAsset(url: url)

        // Load duration and tracks concurrently
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // Video track metadata
        guard let videoTrack = videoTracks.first else {
            throw VideoAssetError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        // Apply transform to get the actual display dimensions (handles rotation)
        let transformedSize = naturalSize.applying(transform)
        let correctedDimensions = CGSize(
            width: abs(transformedSize.width),
            height: abs(transformedSize.height)
        )

        // Validate duration is usable.
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0.1 else {
            throw VideoAssetError.invalidDuration
        }

        // Validate dimensions.
        let correctedW = max(correctedDimensions.width, 1)
        let correctedH = max(correctedDimensions.height, 1)
        let safeDimensions = CGSize(width: correctedW, height: correctedH)

        // Audio track metadata — optional. Videos without audio can still be
        // imported for visual-only angles; they just can't be the sync reference.
        var sampleRate: Int = 0
        var bitrate: Int = 0
        if let audioTrack = audioTracks.first {
            let audioFormatDescriptions = try await audioTrack.load(.formatDescriptions)
            let estimatedDataRate = try await audioTrack.load(.estimatedDataRate)
            if let formatDescription = audioFormatDescriptions.first {
                let absd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
                if let sr = absd?.pointee.mSampleRate { sampleRate = Int(sr) }
            }
            bitrate = max(1, Int(estimatedDataRate)) // At least 1 if audio track exists
        }

        // Generate thumbnail at 25% of video duration.
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
            localURL: url,
            durationSeconds: durationSeconds,
            dimensions: safeDimensions,
            audioBitrate: bitrate,
            audioSampleRate: sampleRate,
            thumbnailData: thumbnailData
        )
    }
}
