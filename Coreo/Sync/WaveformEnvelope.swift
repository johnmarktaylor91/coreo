// WaveformEnvelope.swift
// Coreo
//
// RMS envelope generation for manual waveform sync nudging.

import Foundation

/// One downsampled audio amplitude bucket.
struct WaveformBucket: Equatable {
    /// Start time of this bucket in clip-local seconds.
    let startTimeSeconds: Double

    /// Bucket duration in seconds.
    let durationSeconds: Double

    /// RMS amplitude normalized later by the renderer.
    let amplitude: Float
}

/// Downsampled waveform envelope for one clip.
struct WaveformEnvelope: Equatable {
    /// RMS buckets in clip-local order.
    let buckets: [WaveformBucket]

    /// Source sample rate.
    let sampleRate: Double

    /// True when no audio track was available.
    let hasAudio: Bool
}

/// Pure waveform math and AVFoundation-backed envelope extraction.
enum WaveformEnvelopeBuilder {
    /// Default audio sample rate shared with the sync engine extraction route.
    static let sampleRate: Double = 8000

    /// Default envelope bucket width.
    static let bucketDurationSeconds: Double = 0.035

    /// Maximum buckets retained per clip to keep memory bounded.
    static let maxBucketCount: Int = 4000

    /// Extracts a fixed-size RMS envelope using the same PCM extraction route as audio sync.
    ///
    /// - Parameter url: Video file URL.
    /// - Returns: Downsampled waveform envelope, or a no-audio placeholder.
    static func envelope(from url: URL) async throws -> WaveformEnvelope {
        do {
            let samples = try await AudioExtractor.extractPCM(from: url, targetSampleRate: sampleRate)
            return WaveformEnvelope(
                buckets: downsample(samples: samples, sampleRate: sampleRate),
                sampleRate: sampleRate,
                hasAudio: true
            )
        } catch let error as AudioExtractionError where error == .noAudioTrack {
            return WaveformEnvelope(buckets: [], sampleRate: sampleRate, hasAudio: false)
        }
    }

    /// Converts PCM samples into RMS buckets with averaged remainder handling.
    ///
    /// - Parameters:
    ///   - samples: Mono PCM samples.
    ///   - sampleRate: Samples per second.
    ///   - bucketDurationSeconds: Desired bucket width.
    ///   - maxBucketCount: Maximum buckets to retain after optional second-pass reduction.
    /// - Returns: RMS envelope buckets.
    static func downsample(
        samples: [Float],
        sampleRate: Double,
        bucketDurationSeconds: Double = bucketDurationSeconds,
        maxBucketCount: Int = maxBucketCount
    ) -> [WaveformBucket] {
        guard !samples.isEmpty, sampleRate > 0, bucketDurationSeconds > 0 else {
            return []
        }

        let samplesPerBucket = max(1, Int((sampleRate * bucketDurationSeconds).rounded()))
        var buckets: [WaveformBucket] = []
        buckets.reserveCapacity(Int(ceil(Double(samples.count) / Double(samplesPerBucket))))

        var index = 0
        while index < samples.count {
            let end = min(index + samplesPerBucket, samples.count)
            let slice = samples[index ..< end]
            let sumSquares = slice.reduce(Float(0)) { partial, sample in
                partial + sample * sample
            }
            let rms = sqrt(sumSquares / Float(slice.count))
            buckets.append(WaveformBucket(
                startTimeSeconds: Double(index) / sampleRate,
                durationSeconds: Double(end - index) / sampleRate,
                amplitude: rms
            ))
            index = end
        }

        return reduceBucketsIfNeeded(buckets, maxBucketCount: maxBucketCount)
    }

    /// Converts horizontal drag points to an offset delta.
    ///
    /// - Parameters:
    ///   - points: Horizontal drag distance in points.
    ///   - secondsPerPoint: Scale of the visible waveform strip.
    /// - Returns: Offset delta in seconds. Positive means clip starts later.
    static func offsetDelta(points: CGFloat, secondsPerPoint: Double) -> Double {
        Double(points) * secondsPerPoint
    }

    /// Reduces bucket count with averaged groups when the full envelope is too large.
    ///
    /// - Parameters:
    ///   - buckets: Source RMS buckets.
    ///   - maxBucketCount: Maximum retained count.
    /// - Returns: Original or reduced buckets.
    private static func reduceBucketsIfNeeded(
        _ buckets: [WaveformBucket],
        maxBucketCount: Int
    ) -> [WaveformBucket] {
        guard maxBucketCount > 0, buckets.count > maxBucketCount else {
            return buckets
        }

        let groupSize = Int(ceil(Double(buckets.count) / Double(maxBucketCount)))
        var reduced: [WaveformBucket] = []
        reduced.reserveCapacity(maxBucketCount)

        var index = 0
        while index < buckets.count {
            let end = min(index + groupSize, buckets.count)
            let group = buckets[index ..< end]
            let amplitude = group.reduce(Float(0)) { $0 + $1.amplitude } / Float(group.count)
            let first = group[group.startIndex]
            let last = group[group.index(before: group.endIndex)]
            reduced.append(WaveformBucket(
                startTimeSeconds: first.startTimeSeconds,
                durationSeconds: last.startTimeSeconds + last.durationSeconds - first.startTimeSeconds,
                amplitude: amplitude
            ))
            index = end
        }

        return reduced
    }
}
