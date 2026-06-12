// AudioSyncEngine.swift
// Coreo
//
// Orchestrates multi-video audio sync. Extracts PCM audio from each video,
// runs FFT cross-correlation against a reference track, and produces
// per-video time offsets with confidence scores.

import Foundation

/// Per-video sync state reported by the audio sync engine.
enum SyncStatus: Equatable {
    /// The clip was synced against the selected reference.
    case synced

    /// The clip has no audio track and must be aligned manually.
    case noAudio

    /// Audio extraction or correlation failed for this clip.
    case failed(reason: String)
}

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

    /// Per-video sync state.
    let status: SyncStatus
}

/// Aggregate result of the full sync operation across all videos.
struct AudioSyncOutput {
    /// Index of the video chosen as the reference (offset = 0).
    let referenceIndex: Int

    /// Per-video sync results with offsets, confidence, and status.
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
    case insufficientAudioBearingVideos
    case audioExtractionFailed(index: Int, underlying: Error)
    case correlationFailed

    var errorDescription: String? {
        switch self {
        case .insufficientVideos:
            return "At least 2 videos are required for audio sync."
        case .insufficientAudioBearingVideos:
            return "At least 2 videos with audio are required for automatic sync."
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
/// 5. Reports per-video statuses so the UI can warn about weak or missing audio.
enum AudioSyncEngine {

    /// Correlation confidence below this threshold flags a video as potentially
    /// unmatched. The UI should warn the user and offer manual adjustment.
    static let confidenceThreshold: Float = 0.15

    /// The sample rate used for audio extraction. Must match the default in
    /// ``AudioExtractor`` so that lag-to-seconds conversion is correct.
    private static let sampleRate: Double = 8000

    /// Maximum audio duration used for correlation, in seconds.
    private static let correlationWindowSeconds: Double = 75

    /// Maximum number of expensive pair correlations to run at once.
    private static let maxConcurrentCorrelations: Int = 2

    /// Progress phases emitted by the sync engine.
    enum ProgressPhase: Equatable {
        /// Audio is being extracted from imported clips.
        case extraction

        /// Audio windows are being cross-correlated.
        case correlation
    }

    /// Progress callback. Fraction is normalized from 0...1.
    typealias ProgressHandler = @Sendable (ProgressPhase, Double) -> Void

    /// Extracts audio for a video. Internal seam used by tests.
    typealias AudioProvider = @Sendable (URL, Double) async throws -> [Float]

    /// Sync all videos by audio cross-correlation.
    ///
    /// - Parameter videos: Array of (url, audioBitrate) tuples. Order is preserved
    ///   in the output offsets array.
    /// - Returns: ``AudioSyncOutput`` containing per-video offsets, confidence
    ///   scores, and the recommended audio source.
    /// - Throws: ``SyncError`` if fewer than 2 videos are provided or extraction fails.
    static func sync(
        videos: [(url: URL, audioBitrate: Int)],
        progress: ProgressHandler? = nil
    ) async throws -> AudioSyncOutput {
        try await sync(
            videos: videos,
            progress: progress,
            audioProvider: { url, targetSampleRate in
                try await AudioExtractor.extractPCM(from: url, targetSampleRate: targetSampleRate)
            }
        )
    }

    /// Sync all videos by audio cross-correlation using an injectable audio provider.
    ///
    /// - Parameters:
    ///   - videos: Array of (url, audioBitrate) tuples.
    ///   - progress: Optional progress callback.
    ///   - audioProvider: Async PCM loader used by production extraction and tests.
    /// - Returns: ``AudioSyncOutput`` with per-video statuses.
    /// - Throws: ``SyncError`` if fewer than 2 videos are provided or fewer than 2
    ///   audio-bearing clips remain after extraction.
    static func sync(
        videos: [(url: URL, audioBitrate: Int)],
        progress: ProgressHandler? = nil,
        audioProvider: @escaping AudioProvider
    ) async throws -> AudioSyncOutput {
        guard videos.count >= 2 else {
            throw SyncError.insufficientVideos
        }

        let extracted = await extractAudio(
            videos: videos,
            progress: progress,
            audioProvider: audioProvider
        )
        try Task.checkCancellation()

        let audioBearingIndices = extracted.compactMap { result -> Int? in
            if case .success = result.audio {
                return result.index
            }
            return nil
        }
        guard audioBearingIndices.count >= 2 else {
            throw SyncError.insufficientAudioBearingVideos
        }

        let referenceIndex = chooseReference(videos: videos, candidateIndices: audioBearingIndices)
        guard case .success(let fullReferenceAudio) = extracted[referenceIndex].audio else {
            throw SyncError.insufficientAudioBearingVideos
        }
        let referenceAudio = windowed(fullReferenceAudio)
        let maxCorrelationLength = max(2, referenceAudio.count * 2)
        let fftPlan = FFTHelper.FFTPlan(maxLength: maxCorrelationLength)

        var syncResults = try await correlateAudio(
            extracted: extracted,
            videos: videos,
            referenceIndex: referenceIndex,
            referenceAudio: referenceAudio,
            fftPlan: fftPlan,
            progress: progress
        )
        syncResults.append(
            SyncResult(
                videoIndex: referenceIndex,
                offsetSeconds: 0,
                confidence: 1,
                isReliable: true,
                status: .synced
            )
        )
        syncResults.sort { $0.videoIndex < $1.videoIndex }

        // Build the per-video offsets array. Reference = 0.
        var offsets = [TimeInterval](repeating: 0, count: videos.count)
        for result in syncResults {
            offsets[result.videoIndex] = result.offsetSeconds
        }

        // Audio source = highest bitrate video (same logic as reference selection,
        // but conceptually these could diverge if the selection criteria change).
        let audioSourceIndex = audioBearingIndices.max(by: { videos[$0].audioBitrate < videos[$1].audioBitrate })
            ?? referenceIndex

        return AudioSyncOutput(
            referenceIndex: referenceIndex,
            results: syncResults,
            offsets: offsets,
            audioSourceIndex: audioSourceIndex
        )
    }

    // MARK: - Private

    /// Result of extracting one video's PCM audio.
    private struct ExtractedAudio {
        /// Input index.
        let index: Int

        /// Audio extraction result.
        let audio: Result<[Float], Error>
    }

    /// Extract audio for every input video concurrently.
    private static func extractAudio(
        videos: [(url: URL, audioBitrate: Int)],
        progress: ProgressHandler?,
        audioProvider: @escaping AudioProvider
    ) async -> [ExtractedAudio] {
        await withTaskGroup(of: ExtractedAudio.self) { group in
            for (index, video) in videos.enumerated() {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let audio = try await audioProvider(video.url, sampleRate)
                        try Task.checkCancellation()
                        return ExtractedAudio(index: index, audio: .success(audio))
                    } catch {
                        return ExtractedAudio(index: index, audio: .failure(error))
                    }
                }
            }

            var results = [ExtractedAudio]()
            results.reserveCapacity(videos.count)
            for await result in group {
                results.append(result)
                progress?(.extraction, Double(results.count) / Double(videos.count))
            }

            return results.sorted { $0.index < $1.index }
        }
    }

    /// Correlate each audio-bearing non-reference clip against the reference.
    private static func correlateAudio(
        extracted: [ExtractedAudio],
        videos: [(url: URL, audioBitrate: Int)],
        referenceIndex: Int,
        referenceAudio: [Float],
        fftPlan: FFTHelper.FFTPlan?,
        progress: ProgressHandler?
    ) async throws -> [SyncResult] {
        var pending = extracted.filter { $0.index != referenceIndex }
        var activeCount = 0
        var completedCount = 0
        var results = [SyncResult]()
        results.reserveCapacity(max(0, videos.count - 1))

        let correlatableCount = pending.filter { result in
            if case .success = result.audio {
                return true
            }
            return false
        }.count

        try await withThrowingTaskGroup(of: SyncResult.self) { group in
            func addNextTaskIfPossible() {
                while activeCount < maxConcurrentCorrelations, !pending.isEmpty {
                    let item = pending.removeFirst()
                    switch item.audio {
                    case .success(let fullAudio):
                        activeCount += 1
                        group.addTask {
                            try Task.checkCancellation()
                            let otherAudio = windowed(fullAudio)
                            let (lagSamples, confidence) = try FFTHelper.findOffsetCancellable(
                                signal: otherAudio,
                                reference: referenceAudio,
                                plan: fftPlan
                            )
                            try Task.checkCancellation()
                            let offsetSeconds = Double(lagSamples) / sampleRate

                            return SyncResult(
                                videoIndex: item.index,
                                offsetSeconds: offsetSeconds,
                                confidence: confidence,
                                isReliable: confidence >= confidenceThreshold,
                                status: .synced
                            )
                        }
                    case .failure(let error):
                        completedCount += 1
                        results.append(failedResult(index: item.index, error: error))
                    }
                }
            }

            addNextTaskIfPossible()

            while activeCount > 0, let result = try await group.next() {
                activeCount -= 1
                completedCount += 1
                results.append(result)
                let denominator = max(correlatableCount, 1)
                progress?(.correlation, min(Double(completedCount) / Double(denominator), 1))
                try Task.checkCancellation()
                addNextTaskIfPossible()
            }
        }

        return results.sorted { $0.videoIndex < $1.videoIndex }
    }

    /// Build a failed result for a clip that cannot be used in audio sync.
    private static func failedResult(index: Int, error: Error) -> SyncResult {
        let status: SyncStatus
        if let extractionError = error as? AudioExtractionError, extractionError == .noAudioTrack {
            status = .noAudio
        } else {
            status = .failed(reason: error.localizedDescription)
        }

        return SyncResult(
            videoIndex: index,
            offsetSeconds: 0,
            confidence: 0,
            isReliable: false,
            status: status
        )
    }

    /// Return the bounded audio window used for memory-safe correlation.
    private static func windowed(_ audio: [Float]) -> [Float] {
        let maxSamples = Int(correlationWindowSeconds * sampleRate)
        guard audio.count > maxSamples else {
            return audio
        }
        return Array(audio.prefix(maxSamples))
    }

    /// Choose the reference video index based on audio bitrate (highest wins).
    private static func chooseReference(
        videos: [(url: URL, audioBitrate: Int)],
        candidateIndices: [Int]
    ) -> Int {
        var bestIndex = candidateIndices[0]
        var bestBitrate = videos[bestIndex].audioBitrate

        for index in candidateIndices {
            if videos[index].audioBitrate > bestBitrate {
                bestBitrate = videos[index].audioBitrate
                bestIndex = index
            }
        }

        return bestIndex
    }
}
