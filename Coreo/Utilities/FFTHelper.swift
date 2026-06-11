// FFTHelper.swift
// Coreo
//
// Accelerate framework wrappers for FFT-based cross-correlation used
// to find the time offset between two audio signals during sync.

import Accelerate

/// FFT-based cross-correlation utilities for audio synchronization.
enum FFTHelper {
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
        guard !signal.isEmpty, !reference.isEmpty else {
            return (correlation: [], peakIndex: 0, peakValue: 0)
        }

        // Required FFT length: next power of 2 >= combined length
        let combinedLength = signal.count + reference.count
        let log2n = nextLog2(combinedLength)
        let fftLength = 1 << log2n
        let halfLength = fftLength / 2

        // Set up the FFT
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else {
            return (correlation: [], peakIndex: 0, peakValue: 0)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

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

        // Multiply: FFT(reference) * conj(FFT(signal))
        // conj(signal) = sigR - j*sigI
        // (refR + j*refI)(sigR - j*sigI) = (refR*sigR + refI*sigI) + j*(refI*sigR - refR*sigI)
        var productReal = [Float](repeating: 0, count: halfLength)
        var productImag = [Float](repeating: 0, count: halfLength)

        for i in 0..<halfLength {
            productReal[i] = refReal[i] * signalReal[i] + refImag[i] * signalImag[i]
            productImag[i] = refImag[i] * signalReal[i] - refReal[i] * signalImag[i]
        }

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

        // Scale by 1/(2*N) -- vDSP's inverse FFT leaves a factor of 2*N
        var scale = 1.0 / Float(fftLength * 2)
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
    /// A positive lag means `signal` is delayed relative to `reference`.
    /// A negative lag means `signal` leads `reference`.
    ///
    /// - Parameters:
    ///   - signal: The signal to align.
    ///   - reference: The reference signal.
    /// - Returns: A tuple of lag in samples and normalized confidence (0-1).
    static func findOffset(
        signal: [Float],
        reference: [Float]
    ) -> (lagSamples: Int, confidence: Float) {
        guard !signal.isEmpty, !reference.isEmpty else {
            return (lagSamples: 0, confidence: 0)
        }

        let result = crossCorrelate(signal: signal, reference: reference)

        guard !result.correlation.isEmpty else {
            return (lagSamples: 0, confidence: 0)
        }

        let n = result.correlation.count

        // Interpret the peak index as a signed lag.
        // Indices 0..N/2-1 represent positive lags (signal delayed).
        // Indices N/2..N-1 represent negative lags (signal leads),
        // mapped as index - N.
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
