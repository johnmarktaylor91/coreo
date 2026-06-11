// AudioSyncEngine.swift
// Coreo
//
// Orchestrates multi-video audio sync. Extracts PCM audio from each video,
// runs FFT cross-correlation against a reference track, and produces
// per-video time offsets with confidence scores.

import Foundation

/// Result of syncing one video against the reference.
struct SyncResult {
    /// Index of this video in the original input array.
    let videoIndex: Int

    /// Time offset in seconds. Positive means this video starts after the
    /// reference; negative means it starts before.
    let offsetSeconds: TimeInterval

    /// Normalized confidence score (0-1). Higher values indicate a stronger
    /// correlation peak, meaning the audio match is more reliable.
    let confidence: Float

    /// Whether the confidence exceeds the reliability threshold.
    let isReliable: Bool
}

/// Aggregate result of the full sync operation across all videos.
struct AudioSyncOutput {
    /// Index of the video chosen as the reference (offset = 0).
    let referenceIndex: Int

    /// Per-non-reference-video sync results with offsets and confidence.
    let results: [SyncResult]

    /// Per-video offset array indexed by video position. The reference
    /// video's offset is always 0.0.
    let offsets: [TimeInterval]

    /// Recommended audio source index — the video with the highest
    /// audio bitrate, which typically yields the best listening quality.
    let audioSourceIndex: Int
}

/// Errors that can occur during the sync pipeline.
enum SyncError: Error, LocalizedError {
    case insufficientVideos
    case audioExtractionFailed(index: Int, underlying: Error)
    case correlationFailed

    var errorDescription: String? {
        switch self {
        case .insufficientVideos:
            return "At least 2 videos are required for audio sync."
        case .audioExtractionFailed(let index, let underlying):
            return "Failed to extract audio from video \(index): \(underlying.localizedDescription)"
        case .correlationFailed:
            return "Audio cross-correlation failed."
        }
    }
}

/// Audio-based synchronization engine for multi-angle video.
///
/// The sync algorithm:
/// 1. Selects a reference video (highest audio bitrate, longest if tied).
/// 2. Extracts 8 kHz mono PCM from each video.
/// 3. Cross-correlates each non-reference video against the reference using
///    FFT-based correlation (via ``FFTHelper``).
/// 4. Converts sample-domain lags to time-domain offsets.
/// 5. Reports per-video confidence scores so the UI can warn about weak matches.
enum AudioSyncEngine {

    /// Correlation confidence below this threshold flags a video as potentially
    /// unmatched. The UI should warn the user and offer manual adjustment.
    static let confidenceThreshold: Float = 0.3

    /// The sample rate used for audio extraction. Must match the default in
    /// ``AudioExtractor`` so that lag-to-seconds conversion is correct.
    private static let sampleRate: Double = 8000

    /// Sync all videos by audio cross-correlation.
    ///
    /// - Parameter videos: Array of (url, audioBitrate) tuples. Order is preserved
    ///   in the output offsets array.
    /// - Returns: ``AudioSyncOutput`` containing per-video offsets, confidence
    ///   scores, and the recommended audio source.
    /// - Throws: ``SyncError`` if fewer than 2 videos are provided or extraction fails.
    static func sync(videos: [(url: URL, audioBitrate: Int)]) async throws -> AudioSyncOutput {
        guard videos.count >= 2 else {
            throw SyncError.insufficientVideos
        }

        // Choose reference: highest bitrate. If tied, we break the tie by
        // preferring the first occurrence (the caller can pre-sort by duration
        // if desired, but bitrate is the primary signal for correlation quality).
        let referenceIndex = chooseReference(videos: videos)

        // Extract reference audio.
        let referenceAudio: [Float]
        do {
            referenceAudio = try await AudioExtractor.extractPCM(from: videos[referenceIndex].url,
                                                                  targetSampleRate: sampleRate)
        } catch {
            throw SyncError.audioExtractionFailed(index: referenceIndex, underlying: error)
        }

        // Process all non-reference videos concurrently.
        let syncResults: [SyncResult] = try await withThrowingTaskGroup(of: SyncResult.self) { group in
            for (index, video) in videos.enumerated() where index != referenceIndex {
                let capturedIndex = index
                let capturedURL = video.url

                group.addTask {
                    let otherAudio: [Float]
                    do {
                        otherAudio = try await AudioExtractor.extractPCM(from: capturedURL,
                                                                          targetSampleRate: sampleRate)
                    } catch {
                        throw SyncError.audioExtractionFailed(index: capturedIndex, underlying: error)
                    }

                    let (lagSamples, confidence) = FFTHelper.findOffset(signal: otherAudio,
                                                                       reference: referenceAudio)
                    let offsetSeconds = Double(lagSamples) / sampleRate

                    return SyncResult(
                        videoIndex: capturedIndex,
                        offsetSeconds: offsetSeconds,
                        confidence: confidence,
                        isReliable: confidence >= confidenceThreshold
                    )
                }
            }

            var collected: [SyncResult] = []
            for try await result in group {
                collected.append(result)
            }
            // Sort by original video index for deterministic ordering.
            return collected.sorted { $0.videoIndex < $1.videoIndex }
        }

        // Build the per-video offsets array. Reference = 0.
        var offsets = [TimeInterval](repeating: 0, count: videos.count)
        for result in syncResults {
            offsets[result.videoIndex] = result.offsetSeconds
        }

        // Audio source = highest bitrate video (same logic as reference selection,
        // but conceptually these could diverge if the selection criteria change).
        let audioSourceIndex = videos.indices.max(by: { videos[$0].audioBitrate < videos[$1].audioBitrate })
            ?? referenceIndex

        return AudioSyncOutput(
            referenceIndex: referenceIndex,
            results: syncResults,
            offsets: offsets,
            audioSourceIndex: audioSourceIndex
        )
    }

    // MARK: - Private

    /// Choose the reference video index based on audio bitrate (highest wins).
    private static func chooseReference(videos: [(url: URL, audioBitrate: Int)]) -> Int {
        var bestIndex = 0
        var bestBitrate = videos[0].audioBitrate

        for (index, video) in videos.enumerated() {
            if video.audioBitrate > bestBitrate {
                bestBitrate = video.audioBitrate
                bestIndex = index
            }
        }

        return bestIndex
    }
}
