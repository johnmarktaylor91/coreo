// AudioSyncTests.swift
// CoreoTests
//
// Tests for FFT cross-correlation (FFTHelper) and smart crop geometry
// (SmartCropEngine). These are pure-computation tests that don't require
// AVFoundation or device hardware.

import XCTest
@testable import Coreo

final class AudioSyncTests: XCTestCase {

    // MARK: - FFTHelper: Identical Signals

    /// Two identical signals should produce lag 0 and high confidence.
    func test_findOffset_identicalSignals_returnsZeroLag() {
        let signal = generateSineWave(frequency: 440, sampleRate: 8000, duration: 1.0)

        let (lag, confidence) = FFTHelper.findOffset(signal: signal, reference: signal)

        XCTAssertEqual(lag, 0, "Identical signals should have zero lag")
        XCTAssertGreaterThan(confidence, 0.5, "Identical signals should have high confidence")
    }

    // MARK: - FFTHelper: Known Shift

    /// When the signal is a shifted copy of the reference, findOffset should
    /// recover the shift within a small tolerance.
    func test_findOffset_knownShift_recoversLag() {
        let sampleRate: Float = 8000
        let shiftSamples = 200 // 25 ms shift at 8 kHz

        // Reference: 2 seconds of a composite waveform (multiple frequencies
        // make the correlation peak sharper and more robust).
        var reference = generateSineWave(frequency: 440, sampleRate: sampleRate, duration: 2.0)
        let overlay = generateSineWave(frequency: 880, sampleRate: sampleRate, duration: 2.0)
        for i in 0..<reference.count {
            reference[i] += overlay[i] * 0.5
        }

        // Signal: reference shifted right by shiftSamples (zero-padded at start).
        var signal = [Float](repeating: 0, count: shiftSamples)
        signal.append(contentsOf: reference)

        let (lag, confidence) = FFTHelper.findOffset(signal: signal, reference: reference)

        // The lag should be close to shiftSamples. Allow +-2 samples tolerance
        // because FFT bin resolution introduces slight quantization.
        XCTAssertEqual(lag, shiftSamples, accuracy: 2,
                       "Should recover the known shift of \(shiftSamples) samples")
        XCTAssertGreaterThan(confidence, 0.1,
                             "Shifted copy should still produce meaningful confidence")
    }

    // MARK: - FFTHelper: Negative Shift

    /// When the signal leads the reference (negative lag), findOffset should
    /// return a negative value.
    func test_findOffset_negativeShift_returnsNegativeLag() {
        let sampleRate: Float = 8000
        let shiftSamples = 150

        var reference = generateSineWave(frequency: 440, sampleRate: sampleRate, duration: 2.0)
        let overlay = generateSineWave(frequency: 660, sampleRate: sampleRate, duration: 2.0)
        for i in 0..<reference.count {
            reference[i] += overlay[i] * 0.5
        }

        // Signal starts earlier: pad the reference instead.
        var paddedReference = [Float](repeating: 0, count: shiftSamples)
        paddedReference.append(contentsOf: reference)

        let (lag, _) = FFTHelper.findOffset(signal: reference, reference: paddedReference)

        // Signal leads the padded reference, so lag should be negative.
        XCTAssertLessThan(lag, 0, "Signal that leads reference should produce negative lag")
        XCTAssertEqual(abs(lag), shiftSamples, accuracy: 2,
                       "Magnitude should match the shift")
    }

    // MARK: - FFTHelper: Uncorrelated Signals

    /// Two unrelated signals should produce low confidence.
    func test_findOffset_uncorrelatedSignals_hasLowConfidence() {
        let signal = generateSineWave(frequency: 440, sampleRate: 8000, duration: 1.0)
        let reference = generateSineWave(frequency: 1000, sampleRate: 8000, duration: 1.0)

        // Add some noise to make them less harmonically related.
        var noisyRef = reference
        for i in 0..<noisyRef.count {
            noisyRef[i] += Float.random(in: -0.5...0.5)
        }

        let (_, confidence) = FFTHelper.findOffset(signal: signal, reference: noisyRef)

        // We don't assert a specific lag since it's meaningless for uncorrelated
        // signals. The confidence should be notably lower than correlated signals.
        XCTAssertLessThan(confidence, 0.8,
                          "Uncorrelated signals should have lower confidence than identical ones")
    }

    // MARK: - FFTHelper: Empty Input

    /// Empty signal should return zero lag and zero confidence (graceful no-op).
    func test_findOffset_emptySignal_returnsZeroConfidence() {
        let reference = generateSineWave(frequency: 440, sampleRate: 8000, duration: 0.5)

        let (lag, confidence) = FFTHelper.findOffset(signal: [], reference: reference)

        XCTAssertEqual(lag, 0, "Empty signal should produce zero lag")
        XCTAssertEqual(confidence, 0, "Empty signal should produce zero confidence")
    }

    /// Empty reference should return zero lag and zero confidence (graceful no-op).
    func test_findOffset_emptyReference_returnsZeroConfidence() {
        let signal = generateSineWave(frequency: 440, sampleRate: 8000, duration: 0.5)

        let (lag, confidence) = FFTHelper.findOffset(signal: signal, reference: [])

        XCTAssertEqual(lag, 0, "Empty reference should produce zero lag")
        XCTAssertEqual(confidence, 0, "Empty reference should produce zero confidence")
    }

    // MARK: - FFTHelper: Short Signals

    /// Very short signals (a few samples) should still work without crashing.
    func test_findOffset_veryShortSignals_doesNotCrash() {
        let signal: [Float] = [1, 0, -1, 0, 1]
        let reference: [Float] = [1, 0, -1, 0, 1]

        let (lag, _) = FFTHelper.findOffset(signal: signal, reference: reference)

        XCTAssertEqual(lag, 0, "Identical short signals should have zero lag")
    }

    // MARK: - SmartCropEngine: Basic Crop

    /// A single detected rect should produce a padded crop rect.
    func test_computeCropRect_singleRect_returnsPaddedRect() {
        // Vision coordinates: origin at bottom-left.
        // A person in the center: (0.3, 0.3) with size (0.4, 0.4).
        let rects = [CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)]
        let dimensions = CGSize(width: 1920, height: 1080)

        let result = SmartCropEngine.computeCropRect(detectedRects: rects, videoDimensions: dimensions)

        XCTAssertNotNil(result, "Should return a crop rect for detected persons")

        guard let crop = result else { return }

        // After flipping Y: newY = 1.0 - (0.3 + 0.4) = 0.3
        // After padding (0.15): x = 0.3 - 0.15 = 0.15, y = 0.3 - 0.15 = 0.15
        //                        w = 0.4 + 0.30 = 0.70, h = 0.4 + 0.30 = 0.70
        XCTAssertEqual(crop.origin.x, 0.15, accuracy: 0.001)
        XCTAssertEqual(crop.origin.y, 0.15, accuracy: 0.001)
        XCTAssertEqual(crop.size.width, 0.70, accuracy: 0.001)
        XCTAssertEqual(crop.size.height, 0.70, accuracy: 0.001)
    }

    // MARK: - SmartCropEngine: Multiple Rects Union

    /// Multiple detected rects should be unioned before padding.
    func test_computeCropRect_multipleRects_computesUnionThenPads() {
        let rects = [
            CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3),
            CGRect(x: 0.5, y: 0.4, width: 0.2, height: 0.3)
        ]
        let dimensions = CGSize(width: 1920, height: 1080)

        let result = SmartCropEngine.computeCropRect(detectedRects: rects, videoDimensions: dimensions)

        XCTAssertNotNil(result)

        guard let crop = result else { return }

        // Union in Vision coords: x=0.1, y=0.2, w=0.6, h=0.5
        // (from x=0.1 to x=0.7, from y=0.2 to y=0.7)
        // Flip Y: newY = 1.0 - (0.2 + 0.5) = 0.3
        // So flipped: x=0.1, y=0.3, w=0.6, h=0.5
        // After padding (0.15): x=0.1-0.15=-0.05, y=0.3-0.15=0.15
        //                        w=0.6+0.30=0.90, h=0.5+0.30=0.80
        // Clamped: x=0.0, y=0.15, maxX=min(1,-0.05+0.90)=0.85, maxY=0.15+0.80=0.95
        // w=0.85-0.0=0.85, h=0.95-0.15=0.80
        XCTAssertEqual(crop.origin.x, 0.0, accuracy: 0.001, "X should be clamped to 0")
        XCTAssertEqual(crop.origin.y, 0.15, accuracy: 0.001)
        XCTAssertEqual(crop.size.width, 0.85, accuracy: 0.001)
        XCTAssertEqual(crop.size.height, 0.80, accuracy: 0.001)
    }

    // MARK: - SmartCropEngine: Clamping

    /// Padding that pushes edges beyond [0, 1] should be clamped.
    func test_computeCropRect_edgeRects_clampedToUnitRange() {
        // A person near the top-right in Vision coords.
        let rects = [CGRect(x: 0.8, y: 0.8, width: 0.15, height: 0.15)]
        let dimensions = CGSize(width: 1920, height: 1080)

        let result = SmartCropEngine.computeCropRect(detectedRects: rects, videoDimensions: dimensions)

        XCTAssertNotNil(result)

        guard let crop = result else { return }

        // After flip: y = 1.0 - (0.8 + 0.15) = 0.05
        // After padding: x = 0.8 - 0.15 = 0.65, y = 0.05 - 0.15 = -0.10
        //                w = 0.15 + 0.30 = 0.45, h = 0.15 + 0.30 = 0.45
        // Clamped: x=0.65, y=0.0, maxX=min(1.0, 0.65+0.45)=1.0, maxY=min(1.0, -0.10+0.45)=0.35
        // w=1.0-0.65=0.35, h=0.35-0.0=0.35
        XCTAssertGreaterThanOrEqual(crop.origin.x, 0.0)
        XCTAssertGreaterThanOrEqual(crop.origin.y, 0.0)
        XCTAssertLessThanOrEqual(crop.origin.x + crop.size.width, 1.0 + 0.001)
        XCTAssertLessThanOrEqual(crop.origin.y + crop.size.height, 1.0 + 0.001)
    }

    // MARK: - SmartCropEngine: Empty Rects

    /// No detected persons should return nil (use full frame).
    func test_computeCropRect_emptyRects_returnsNil() {
        let result = SmartCropEngine.computeCropRect(
            detectedRects: [],
            videoDimensions: CGSize(width: 1920, height: 1080)
        )

        XCTAssertNil(result, "Empty detections should return nil to signal full-frame fallback")
    }

    // MARK: - SmartCropEngine: Custom Padding

    /// Zero padding should produce the exact flipped union rect.
    func test_computeCropRect_zeroPadding_returnsExactFlippedUnion() {
        let rects = [CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3)]
        let dimensions = CGSize(width: 1920, height: 1080)

        let result = SmartCropEngine.computeCropRect(
            detectedRects: rects,
            videoDimensions: dimensions,
            padding: 0.0
        )

        XCTAssertNotNil(result)

        guard let crop = result else { return }

        // Flip Y: newY = 1.0 - (0.3 + 0.3) = 0.4
        XCTAssertEqual(crop.origin.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(crop.origin.y, 0.4, accuracy: 0.001)
        XCTAssertEqual(crop.size.width, 0.4, accuracy: 0.001)
        XCTAssertEqual(crop.size.height, 0.3, accuracy: 0.001)
    }

    // MARK: - Helpers

    /// Generate a sine wave at the given frequency and sample rate.
    private func generateSineWave(frequency: Float, sampleRate: Float, duration: Float) -> [Float] {
        let sampleCount = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: sampleCount)

        for i in 0..<sampleCount {
            let t = Float(i) / sampleRate
            samples[i] = sinf(2.0 * .pi * frequency * t)
        }

        return samples
    }
}
