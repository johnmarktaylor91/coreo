// FFTHelper.swift
// Coreo
//
// Accelerate framework wrappers for FFT-based cross-correlation used
// to find the time offset between two audio signals during sync.

import Accelerate

/// FFT-based cross-correlation utilities for audio synchronization.
enum FFTHelper {
    /// Reusable FFT setup for correlations whose padded length is no larger
    /// than the configured maximum.
    final class FFTPlan {
        /// Maximum supported base-2 exponent.
        let maxLog2n: Int

        /// Underlying vDSP setup.
        fileprivate let setup: FFTSetup

        /// Create a reusable FFT setup.
        ///
        /// - Parameter maxLength: Maximum padded FFT length the plan will handle.
        init?(maxLength: Int) {
            maxLog2n = FFTHelper.nextLog2(maxLength)
            guard let setup = vDSP_create_fftsetup(vDSP_Length(maxLog2n), FFTRadix(kFFTRadix2)) else {
                return nil
            }
            self.setup = setup
        }

        deinit {
            vDSP_destroy_fftsetup(setup)
        }
    }

    /// Computes the cross-correlation between two signals using FFT.
    ///
    /// The correlation peak indicates the lag (in samples) at which the
    /// two signals best align. Uses the frequency-domain approach:
    /// IFFT(FFT(reference) * conj(FFT(signal))).
    ///
    /// - Parameters:
    ///   - signal: The signal to align (e.g., audio from a secondary camera).
    ///   - reference: The reference signal to align against (e.g., audio from the main camera).
    /// - Returns: A tuple of the full correlation array, the index of the peak, and the peak value.
    static func crossCorrelate(
        signal: [Float],
        reference: [Float]
    ) -> (correlation: [Float], peakIndex: Int, peakValue: Float) {
        return crossCorrelate(signal: signal, reference: reference, plan: nil)
    }

    /// Computes the cross-correlation using an optional reusable FFT setup.
    ///
    /// - Parameters:
    ///   - signal: The signal to align.
    ///   - reference: The reference signal to align against.
    ///   - plan: Optional reusable FFT plan.
    /// - Returns: A tuple of the full correlation array, peak index, and peak value.
    static func crossCorrelate(
        signal: [Float],
        reference: [Float],
        plan: FFTPlan?
    ) -> (correlation: [Float], peakIndex: Int, peakValue: Float) {
        guard !signal.isEmpty, !reference.isEmpty else {
            return (correlation: [], peakIndex: 0, peakValue: 0)
        }

        // Required FFT length: next power of 2 >= combined length
        let combinedLength = signal.count + reference.count
        let log2n = nextLog2(combinedLength)
        let fftLength = 1 << log2n
        let halfLength = fftLength / 2

        // Set up the FFT.
        let createdSetup: FFTSetup?
        let fftSetup: FFTSetup
        if let plan, plan.maxLog2n >= log2n {
            createdSetup = nil
            fftSetup = plan.setup
        } else if let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) {
            createdSetup = setup
            fftSetup = setup
        } else {
            return (correlation: [], peakIndex: 0, peakValue: 0)
        }
        defer {
            if let createdSetup {
                vDSP_destroy_fftsetup(createdSetup)
            }
        }

        // Zero-pad both signals to fftLength
        var paddedSignal = [Float](repeating: 0, count: fftLength)
        var paddedReference = [Float](repeating: 0, count: fftLength)
        paddedSignal.replaceSubrange(0..<signal.count, with: signal)
        paddedReference.replaceSubrange(0..<reference.count, with: reference)

        // Convert to split complex format for FFT
        var signalReal = [Float](repeating: 0, count: halfLength)
        var signalImag = [Float](repeating: 0, count: halfLength)
        var refReal = [Float](repeating: 0, count: halfLength)
        var refImag = [Float](repeating: 0, count: halfLength)

        // Pack interleaved real data into split complex (even indices -> real, odd -> imag)
        paddedSignal.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfLength) { src in
                signalReal.withUnsafeMutableBufferPointer { rBuf in
                    signalImag.withUnsafeMutableBufferPointer { iBuf in
                        var splitComplex = DSPSplitComplex(
                            realp: rBuf.baseAddress!,
                            imagp: iBuf.baseAddress!
                        )
                        vDSP_ctoz(src, 2, &splitComplex, 1, vDSP_Length(halfLength))
                    }
                }
            }
        }

        paddedReference.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfLength) { src in
                refReal.withUnsafeMutableBufferPointer { rBuf in
                    refImag.withUnsafeMutableBufferPointer { iBuf in
                        var splitComplex = DSPSplitComplex(
                            realp: rBuf.baseAddress!,
                            imagp: iBuf.baseAddress!
                        )
                        vDSP_ctoz(src, 2, &splitComplex, 1, vDSP_Length(halfLength))
                    }
                }
            }
        }

        // Forward FFT of signal
        signalReal.withUnsafeMutableBufferPointer { rBuf in
            signalImag.withUnsafeMutableBufferPointer { iBuf in
                var splitComplex = DSPSplitComplex(
                    realp: rBuf.baseAddress!,
                    imagp: iBuf.baseAddress!
                )
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
            }
        }

        // Forward FFT of reference
        refReal.withUnsafeMutableBufferPointer { rBuf in
            refImag.withUnsafeMutableBufferPointer { iBuf in
                var splitComplex = DSPSplitComplex(
                    realp: rBuf.baseAddress!,
                    imagp: iBuf.baseAddress!
                )
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
            }
        }

        // Multiply: FFT(reference) * conj(FFT(signal)).
        var productReal = [Float](repeating: 0, count: halfLength)
        var productImag = [Float](repeating: 0, count: halfLength)

        refReal.withUnsafeMutableBufferPointer { refRBuf in
            refImag.withUnsafeMutableBufferPointer { refIBuf in
                signalReal.withUnsafeMutableBufferPointer { signalRBuf in
                    signalImag.withUnsafeMutableBufferPointer { signalIBuf in
                        productReal.withUnsafeMutableBufferPointer { productRBuf in
                            productImag.withUnsafeMutableBufferPointer { productIBuf in
                                var signalSplit = DSPSplitComplex(
                                    realp: signalRBuf.baseAddress!,
                                    imagp: signalIBuf.baseAddress!
                                )
                                var referenceSplit = DSPSplitComplex(
                                    realp: refRBuf.baseAddress!,
                                    imagp: refIBuf.baseAddress!
                                )
                                var productSplit = DSPSplitComplex(
                                    realp: productRBuf.baseAddress!,
                                    imagp: productIBuf.baseAddress!
                                )
                                vDSP_zvmul(
                                    &signalSplit,
                                    1,
                                    &referenceSplit,
                                    1,
                                    &productSplit,
                                    1,
                                    vDSP_Length(halfLength),
                                    -1
                                )
                            }
                        }
                    }
                }
            }
        }

        // In zrip packing, index 0 stores DC in realp and Nyquist in imagp.
        // They are both real-valued bins, so handle them outside complex math.
        productReal[0] = refReal[0] * signalReal[0]
        productImag[0] = refImag[0] * signalImag[0]

        // Inverse FFT to get correlation
        productReal.withUnsafeMutableBufferPointer { rBuf in
            productImag.withUnsafeMutableBufferPointer { iBuf in
                var splitComplex = DSPSplitComplex(
                    realp: rBuf.baseAddress!,
                    imagp: iBuf.baseAddress!
                )
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Inverse))
            }
        }

        // Convert split complex back to interleaved real
        var correlation = [Float](repeating: 0, count: fftLength)
        productReal.withUnsafeMutableBufferPointer { rBuf in
            productImag.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(
                    realp: rBuf.baseAddress!,
                    imagp: iBuf.baseAddress!
                )
                correlation.withUnsafeMutableBufferPointer { outBuf in
                    outBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfLength) { dst in
                        vDSP_ztoc(&split, 1, dst, 2, vDSP_Length(halfLength))
                    }
                }
            }
        }

        // Scale by 1/N after the inverse transform.
        var scale = 1.0 / Float(fftLength)
        vDSP_vsmul(correlation, 1, &scale, &correlation, 1, vDSP_Length(fftLength))

        // Find peak
        var peakValue: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxvi(correlation, 1, &peakValue, &peakIndex, vDSP_Length(fftLength))

        return (
            correlation: correlation,
            peakIndex: Int(peakIndex),
            peakValue: peakValue
        )
    }

    /// Finds the optimal lag in samples between two signals.
    ///
    /// A negative lag means `signal` content is delayed relative to
    /// `reference` content. A positive lag means `signal` content leads
    /// `reference` content, which maps to a camera that started recording
    /// later than the reference.
    ///
    /// - Parameters:
    ///   - signal: The signal to align.
    ///   - reference: The reference signal.
    /// - Returns: A tuple of lag in samples and normalized confidence (0-1).
    static func findOffset(
        signal: [Float],
        reference: [Float]
    ) -> (lagSamples: Int, confidence: Float) {
        return findOffset(signal: signal, reference: reference, plan: nil)
    }

    /// Finds the optimal lag in samples between two signals.
    ///
    /// A negative lag means `signal` content is delayed relative to
    /// `reference` content. A positive lag means `signal` content leads
    /// `reference` content, which maps to a camera that started recording
    /// later than the reference.
    ///
    /// - Parameters:
    ///   - signal: The signal to align.
    ///   - reference: The reference signal.
    ///   - plan: Optional reusable FFT plan.
    /// - Returns: A tuple of lag in samples and normalized confidence (0-1).
    static func findOffset(
        signal: [Float],
        reference: [Float],
        plan: FFTPlan?
    ) -> (lagSamples: Int, confidence: Float) {
        guard !signal.isEmpty, !reference.isEmpty else {
            return (lagSamples: 0, confidence: 0)
        }

        let result = crossCorrelate(signal: signal, reference: reference, plan: plan)

        guard !result.correlation.isEmpty else {
            return (lagSamples: 0, confidence: 0)
        }

        let n = result.correlation.count

        // Interpret the peak index as a signed lag.
        // Positive lags mean signal content leads reference content.
        // Negative lags mean signal content is delayed relative to reference.
        var lag = result.peakIndex
        if lag > n / 2 {
            lag = lag - n
        }

        // Normalize confidence: peak / sqrt(energy_signal * energy_reference)
        var signalEnergy: Float = 0
        var referenceEnergy: Float = 0
        vDSP_dotpr(signal, 1, signal, 1, &signalEnergy, vDSP_Length(signal.count))
        vDSP_dotpr(reference, 1, reference, 1, &referenceEnergy, vDSP_Length(reference.count))

        let denominator = sqrtf(signalEnergy * referenceEnergy)
        let confidence: Float
        if denominator > 0 {
            confidence = min(abs(result.peakValue) / denominator, 1.0)
        } else {
            confidence = 0
        }

        return (lagSamples: lag, confidence: confidence)
    }

    /// Finds the optimal lag while cooperatively observing task cancellation.
    ///
    /// - Parameters:
    ///   - signal: The signal to align.
    ///   - reference: The reference signal.
    ///   - plan: Optional reusable FFT plan.
    /// - Returns: A tuple of lag in samples and normalized confidence (0-1).
    /// - Throws: `CancellationError` when the current task is cancelled.
    static func findOffsetCancellable(
        signal: [Float],
        reference: [Float],
        plan: FFTPlan?
    ) throws -> (lagSamples: Int, confidence: Float) {
        try Task.checkCancellation()
        let result = findOffset(signal: signal, reference: reference, plan: plan)
        try Task.checkCancellation()
        return result
    }

    // MARK: - Private Helpers

    /// Compute the smallest power-of-two exponent such that 2^exp >= value.
    private static func nextLog2(_ value: Int) -> Int {
        var exp = 1
        while (1 << exp) < value {
            exp += 1
        }
        return exp
    }
}
