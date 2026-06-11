// PersonDetector.swift
// Coreo
//
// Vision-based human detection for the smart crop system. Samples frames
// from a video at regular intervals and runs VNDetectHumanRectanglesRequest
// on each to build a map of where people appear throughout the clip.

import AVFoundation
import CoreGraphics
import Vision

/// Errors that can occur during person detection.
enum PersonDetectionError: Error, LocalizedError {
    case assetLoadFailed
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .assetLoadFailed:
            return "Failed to load the video asset for person detection."
        case .noVideoTrack:
            return "The video file does not contain a video track."
        }
    }
}

/// Detects human figures in sampled video frames using the Vision framework.
///
/// Samples frames at a configurable interval (default 2.5s) and runs
/// `VNDetectHumanRectanglesRequest` on each. Returns all detected bounding
/// boxes in Vision coordinates (normalized 0-1, origin at bottom-left) for
/// downstream crop computation by ``SmartCropEngine``.
enum PersonDetector {

    /// Detect human bounding boxes in sampled frames from a video.
    ///
    /// - Parameters:
    ///   - url: URL to the video file.
    ///   - sampleInterval: Time between sampled frames in seconds (default 2.5).
    /// - Returns: Array of detected bounding boxes in Vision coordinates
    ///   (normalized 0-1, origin at bottom-left). May be empty if no humans
    ///   are found in any frame.
    /// - Throws: `PersonDetectionError` if the video can't be loaded.
    static func detectPersons(in url: URL, sampleInterval: Double = 2.5) async throws -> [CGRect] {
        let asset = AVURLAsset(url: url)

        // Verify there is a video track.
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw PersonDetectionError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        guard durationSeconds > 0 else {
            return []
        }

        // Compute sample times spread across the video duration.
        let sampleTimes = buildSampleTimes(durationSeconds: durationSeconds,
                                           interval: sampleInterval)

        guard !sampleTimes.isEmpty else {
            return []
        }

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        // Cap the generated image size to limit memory usage during detection.
        imageGenerator.maximumSize = CGSize(width: 1280, height: 1280)
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        // Run detection on a background thread.
        let detectedRects: [CGRect] = try await Task.detached(priority: .userInitiated) {
            var allRects: [CGRect] = []

            for sampleTime in sampleTimes {
                try Task.checkCancellation()

                let cmTime = CMTime(seconds: sampleTime, preferredTimescale: 600)

                // autoreleasepool ensures each CGImage (~6MB at 1280px) is
                // released before the next frame is generated.
                let rects: [CGRect] = try autoreleasepool {
                    let cgImage: CGImage
                    do {
                        var actualTime = CMTime.zero
                        cgImage = try imageGenerator.copyCGImage(at: cmTime, actualTime: &actualTime)
                    } catch {
                        return []
                    }

                    return try detectHumans(in: cgImage)
                }
                allRects.append(contentsOf: rects)
            }

            return allRects
        }.value

        return detectedRects
    }

    // MARK: - Private

    /// Build an array of sample times evenly spaced through the video.
    ///
    /// Always includes a sample near the start (0.5s in) and respects
    /// the interval spacing throughout.
    private static func buildSampleTimes(durationSeconds: Double, interval: Double) -> [Double] {
        guard durationSeconds > 0, interval > 0 else { return [] }

        var times: [Double] = []
        var t = min(0.5, durationSeconds * 0.5)

        while t < durationSeconds {
            times.append(t)
            t += interval
        }

        return times
    }

    /// Run VNDetectHumanRectanglesRequest on a single CGImage.
    ///
    /// - Parameter image: The frame to analyze.
    /// - Returns: Bounding boxes of detected humans in Vision coordinates.
    private static func detectHumans(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectHumanRectanglesRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else {
            return []
        }

        return observations.map { $0.boundingBox }
    }
}
