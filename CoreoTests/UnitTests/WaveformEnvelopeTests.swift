// WaveformEnvelopeTests.swift
// CoreoTests

@testable import Coreo
import XCTest

final class WaveformEnvelopeTests: XCTestCase {
    func testDownsampleAveragesBucketsAndRemainder() {
        let samples: [Float] = [1, 1, 3, 3, 2]

        let buckets = WaveformEnvelopeBuilder.downsample(
            samples: samples,
            sampleRate: 10,
            bucketDurationSeconds: 0.2,
            maxBucketCount: 10
        )

        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[0].amplitude, 1, accuracy: 0.0001)
        XCTAssertEqual(buckets[1].amplitude, 3, accuracy: 0.0001)
        XCTAssertEqual(buckets[2].amplitude, 2, accuracy: 0.0001)
        XCTAssertEqual(buckets[2].durationSeconds, 0.1, accuracy: 0.0001)
    }

    func testDownsampleReducesToMaximumBucketCountWithAveraging() {
        let samples = [Float](repeating: 1, count: 12)

        let buckets = WaveformEnvelopeBuilder.downsample(
            samples: samples,
            sampleRate: 12,
            bucketDurationSeconds: 1.0 / 12.0,
            maxBucketCount: 5
        )

        XCTAssertEqual(buckets.count, 4)
        XCTAssertTrue(buckets.allSatisfy { abs($0.amplitude - 1) < 0.0001 })
    }

    func testDragRightMapsToPositiveCanonicalOffset() {
        let delta = WaveformEnvelopeBuilder.offsetDelta(points: 30, secondsPerPoint: 0.01)

        XCTAssertEqual(delta, 0.3, accuracy: 0.0001)
    }

    func testDragRightMeansClipStartsLaterByConvention() {
        let originalOffset = 1.0
        let delta = WaveformEnvelopeBuilder.offsetDelta(points: 15, secondsPerPoint: 0.02)
        let newOffset = originalOffset + delta
        let timelineTime = 8.0

        XCTAssertEqual(newOffset, 1.3, accuracy: 0.0001)
        XCTAssertEqual(timelineTime - newOffset, 6.7, accuracy: 0.0001)
    }
}
